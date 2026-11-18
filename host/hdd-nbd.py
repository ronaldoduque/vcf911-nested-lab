# hdd-nbd.py - servidor NBD SOMENTE LEITURA para o ESXi entregar um disco local a uma VM pela rede.
# Uso no ESXi:  python /tmp/hdd-nbd.py <ID do disco> <IP permitido> [porta] [tamanho em bytes]
# Não grava nada no disco: escrita é recusada.
import os, socket, struct, sys, threading

dev = sys.argv[1] if sys.argv[1].startswith('/') else '/vmfs/devices/disks/' + sys.argv[1]
allow = sys.argv[2]
port = int(sys.argv[3]) if len(sys.argv) > 3 else 10809
IHAVEOPT = 0x49484156454F5054
REPMAGIC = 0x3e889045565a9

fd = os.open(dev, os.O_RDONLY)
size = os.lseek(fd, 0, 2)
if size <= 0 and len(sys.argv) > 4:
    size = int(sys.argv[4])
if size <= 0:
    sys.exit('tamanho do disco = 0: confira o ID')
print('disco %s: %d bytes (%.1f GB), só leitura, porta %d, cliente permitido %s' % (dev, size, size / 1e9, port, allow))
sys.stdout.flush()

def recvall(c, n):
    b = b''
    while len(b) < n:
        x = c.recv(n - len(b))
        if not x:
            raise EOFError
        b += x
    return b

def reply(c, opt, typ, data=b''):
    c.sendall(struct.pack('>QIII', REPMAGIC, opt, typ, len(data)) + data)

TFLAGS = 1 | 2 | 4   # HAS_FLAGS | READ_ONLY | SEND_FLUSH

def serve(c):
    c.sendall(b'NBDMAGIC' + struct.pack('>QH', IHAVEOPT, 1 | 2))
    cflags = struct.unpack('>I', recvall(c, 4))[0]
    while True:
        magic, opt, ln = struct.unpack('>QII', recvall(c, 16))
        data = recvall(c, ln) if ln else b''
        if opt == 1:                       # EXPORT_NAME
            c.sendall(struct.pack('>QH', size, TFLAGS) + (b'' if cflags & 2 else b'\0' * 124))
            break
        elif opt in (6, 7):                # INFO / GO
            reply(c, opt, 3, struct.pack('>HQH', 0, size, TFLAGS))
            reply(c, opt, 1)
            if opt == 7:
                break
        elif opt == 2:                     # ABORT
            reply(c, opt, 1)
            return
        else:
            reply(c, opt, 0x80000001)      # não suportado
    while True:
        magic, flags, typ, handle, off, ln = struct.unpack('>IHHQQI', recvall(c, 28))
        if typ == 0:                       # READ
            buf = b''
            while len(buf) < ln:
                x = os.pread(fd, ln - len(buf), off + len(buf))
                if not x:
                    break
                buf += x
            buf += b'\0' * (ln - len(buf))
            c.sendall(struct.pack('>IIQ', 0x67446698, 0, handle) + buf)
        elif typ == 1:                     # WRITE: recusa (EPERM)
            recvall(c, ln)
            c.sendall(struct.pack('>IIQ', 0x67446698, 1, handle))
        elif typ == 2:                     # DISC
            return
        elif typ == 3:                     # FLUSH
            c.sendall(struct.pack('>IIQ', 0x67446698, 0, handle))
        else:
            c.sendall(struct.pack('>IIQ', 0x67446698, 22, handle))

def client(c, a):
    print('conectado: %s:%d' % a); sys.stdout.flush()
    try:
        serve(c)
    except (EOFError, OSError):
        pass
    c.close()
    print('desconectado: %s:%d' % a); sys.stdout.flush()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', port))
s.listen(4)
while True:
    c, a = s.accept()
    if a[0] != allow:
        print('recusado: %s' % a[0]); c.close(); continue
    c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    threading.Thread(target=client, args=(c, a), daemon=True).start()
