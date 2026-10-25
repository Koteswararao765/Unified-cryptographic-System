import sys
import time
import hmac
import hashlib

import serial
from serial.tools import list_ports

DEFAULT_PORT = "COM5"      # or: py .\crypto.py COM7
BAUD_RATE = 115200
RESP_TIMEOUT = 10.0        # seconds (one 256-bit scalar multiplication ~0.3 s)

# secp256k1 domain parameters
P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)

HEXCHARS = set("0123456789abcdefABCDEF")

ERRORS = {
    "ERROR_ECC": "scalar multiplication gave the point at infinity (key/ephemeral value is 0 or invalid, "
                 "or no private key has been loaded yet).",
    "ERROR_PT":  "the supplied public point is NOT on secp256k1 (invalid / malicious point rejected).",
    "ERROR_TAG": "authentication failed: wrong private key, or R / ciphertext / tag was altered.",
    "ERROR_LEN": "frame length wrong.",
}


# ---------------------------------------------------------------------------
# Small software ECC / ECIES reference. Used ONLY to cross-check the FPGA and
# to validate user input - the FPGA does the real work.
# ---------------------------------------------------------------------------
def ec_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    if a == b:
        lam = 3 * a[0] * a[0] * pow(2 * a[1], -1, P) % P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], -1, P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return (x, (lam * (a[0] - x) - a[1]) % P)


def ec_mul(k, pt):
    r = None
    while k:
        if k & 1:
            r = ec_add(r, pt)
        pt = ec_add(pt, pt)
        k >>= 1
    return r


def on_curve(pt):
    x, y = pt
    return 0 <= x < P and 0 <= y < P and (y * y - x * x * x - 7) % P == 0


def kdf(shared_x):
    """X9.63-style KDF: SHA-256(Sx || 00000001) -> (K_enc, K_mac), 16 bytes each."""
    d = hashlib.sha256(shared_x.to_bytes(32, "big") + (1).to_bytes(4, "big")).digest()
    return d[:16], d[16:]


def aes_ecb_encrypt(key, block):
    """Optional AES cross-check (needs pycryptodome or cryptography). Returns None if unavailable."""
    try:
        from Crypto.Cipher import AES
        return AES.new(key, AES.MODE_ECB).encrypt(block)
    except ImportError:
        pass
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
        return enc.update(block) + enc.finalize()
    except ImportError:
        return None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def is_hex(s, n):
    return len(s) == n and all(c in HEXCHARS for c in s)


def h64(x):
    return f"{x:064x}"



def ask_scalar(prompt):
    """Ask for a private key. Accepted forms:
         3, 4, 25          -> decimal number
         0x1F, 0xdeadbeef  -> hex (needs the 0x prefix)
         64 hex characters -> full-length hex key
       Must satisfy 1 <= key < n. Returns int or None."""
    s = input(prompt).strip().lower().replace(" ", "").replace("_", "")
    try:
        if s.startswith("0x"):
            v = int(s[2:], 16)
        elif len(s) == 64 and is_hex(s, 64):
            v = int(s, 16)
        else:
            v = int(s, 10)
    except ValueError:
        print("[ERROR] Enter a decimal number (e.g. 3), or hex with a 0x prefix (e.g. 0x1f).\n")
        return None
    if not (1 <= v < N):
        print("[ERROR] Key must satisfy 1 <= key < n.\n")
        return None
    print(f"   (using key = {v}  =  0x{v:x})")
    return v


def show_ports():
    ports = list(list_ports.comports())
    if not ports:
        print("  (no serial ports found - is the board powered and the USB cable plugged in?)")
    for p in ports:
        print(f"  {p.device}: {p.description}")


def open_port(name):
    try:
        return serial.Serial(name, BAUD_RATE, timeout=0.1, write_timeout=2)
    except serial.SerialException as e:
        print(f"\n[ERROR] Cannot open {name}: {e}")
        print("  'Access is denied' = another program (or an old python.exe) holds the port.")
        print("  Ports currently present:")
        show_ports()
        return None


def transact(ser, message, timeout=RESP_TIMEOUT):
    """Send one line, return first response line (stripped) or None on timeout."""
    ser.reset_input_buffer()
    ser.write(message.encode("ascii"))
    ser.flush()
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        chunk = ser.read(ser.in_waiting or 1)
        if chunk:
            buf += chunk
            if b"\n" in buf:
                return buf.split(b"\n", 1)[0].decode("ascii", errors="replace").strip()
    return None if not buf else buf.decode("ascii", errors="replace").strip()


def report_error(resp):
    if resp is None:
        print("[TIMEOUT] No response from FPGA.\n")
        return
    for key, text in ERRORS.items():
        if resp.startswith(key):
            print(f"[{key}] {text}\n")
            return
    print(f"[WARNING] Unexpected response ({len(resp)} chars): {resp}\n")


def ask_hex(prompt, nchars, default=None):
    s = input(prompt).strip().replace(" ", "")
    if s.lower().startswith("0x"):
        s = s[2:]
    if not s and default is not None:
        return default
    if not is_hex(s, nchars):
        print(f"[ERROR] Need exactly {nchars} hex characters.\n")
        return None
    return s.lower()


# ---------------------------------------------------------------------------
# FPGA operations
# ---------------------------------------------------------------------------
def fpga_set_private(ser, d):
    resp = transact(ser, f"K{h64(d)}\n")
    if resp is not None and resp.startswith("OK_PRIV"):
        return True
    report_error(resp)
    return False


def fpga_get_public(ser):
    resp = transact(ser, "U\n")
    if resp is not None and len(resp) == 128 and is_hex(resp, 128):
        return int(resp[:64], 16), int(resp[64:], 16)
    report_error(resp)
    return None


def fpga_set_recipient(ser, q):
    resp = transact(ser, f"Q{h64(q[0])}{h64(q[1])}\n")
    if resp is not None and resp.startswith("OK_PUB"):
        return True
    report_error(resp)
    return False


def fpga_encrypt(ser, ks, pt_hex):
    resp = transact(ser, f"P{h64(ks)}{pt_hex}\n")
    if resp is not None and len(resp) == 224 and is_hex(resp, 224):
        resp = resp.lower()                               # FPGA sends upper-case hex
        return resp[:128], resp[128:160], resp[160:]      # R(128) CT(32) TAG(64)
    report_error(resp)
    return None


def fpga_decrypt(ser, r_hex, ct, tag):
    resp = transact(ser, f"R{r_hex}{ct}{tag}\n")
    if resp is not None and len(resp) == 32 and is_hex(resp, 32):
        return resp.lower()
    report_error(resp)
    return None


# ---------------------------------------------------------------------------
# Menu actions
# ---------------------------------------------------------------------------
def pt_from_text(s):
    s = s.strip()
    if is_hex(s, 32):
        return s.lower()
    if 0 < len(s.encode()) <= 16:
        padded = s.encode().ljust(16, b"\x00")
        print(f"   (text zero-padded to 16 bytes: {padded.hex()})")
        return padded.hex()
    print("[ERROR] Enter 32 hex characters, or up to 16 characters of text.\n")
    return None


def show_plain(pt_hex):
    raw = bytes.fromhex(pt_hex)
    txt = raw.rstrip(b"\x00")
    shown = txt.decode("ascii", errors="replace") if txt and all(32 <= b < 127 for b in txt) else None
    print(f"   Plaintext:  {pt_hex}" + (f'   ("{shown}")' if shown else ""))


def sw_check_encrypt(ks, q, pt_hex, r_hex, ct_hex, tag_hex):
    """Recompute the sender's output in software (uses only r and the PUBLIC key Q)."""
    ok = True
    rr = ec_mul(ks, G)
    good_r = (r_hex == h64(rr[0]) + h64(rr[1]))
    print(f"   [check] R = ks*G                      : {'OK' if good_r else 'MISMATCH'}")
    ok &= good_r
    s = ec_mul(ks, q)
    k_enc, k_mac = kdf(s[0])
    good_tag = hmac.compare_digest(hmac.new(k_mac, bytes.fromhex(ct_hex), hashlib.sha256).digest(),
                                   bytes.fromhex(tag_hex))
    print(f"   [check] KDF + HMAC-SHA256 tag         : {'OK' if good_tag else 'MISMATCH'}")
    ok &= good_tag
    ct_sw = aes_ecb_encrypt(k_enc, bytes.fromhex(pt_hex))
    if ct_sw is None:
        print("   [check] AES ciphertext                : skipped (pip install pycryptodome to enable)")
    else:
        good_ct = ct_sw.hex() == ct_hex
        print(f"   [check] AES-128 ciphertext            : {'OK' if good_ct else 'MISMATCH'}")
        ok &= good_ct
    return ok


class Session:
    def __init__(self, ser):
        self.ser = ser
        self.kr = None           # receiver private key (PC copy, only for the optional cross-check)
        self.pub = None          # receiver public key as read back from the FPGA
        self.recipient = None    # sender-side: recipient public key (public data only)
        self.package = None      # last (R, CT, TAG) produced by the sender

    # ---- receiver ----
    def set_private(self):
        kr = ask_scalar("Receiver private key kr : ")
        if kr is None:
            return
        if not fpga_set_private(self.ser, kr):
            return
        self.kr = kr
        print("[OK] receiver private key kr loaded into the FPGA. Computing Q = kr*G on the FPGA...")
        self.read_public()

    def read_public(self):
        q = fpga_get_public(self.ser)
        if q is None:
            return
        self.pub = q
        print(f"   Receiver public key Q:\n     Qx = {h64(q[0])}\n     Qy = {h64(q[1])}")
        if self.kr is not None:
            qs = ec_mul(self.kr, G)
            print(f"   [check] FPGA Q equals software kr*G    : {'OK' if q == qs else 'MISMATCH'}")
        print("   (publish Q - the sender needs only this)\n")

    def decrypt(self, pkg=None):
        if pkg is None:
            default = self.package
            print("Received message package (Enter = use the last one produced by the sender)" if default
                  else "Received message package:")
            r_hex = ask_hex("  R = Rx||Ry (128 hex): ", 128, default[0] if default else None)
            if r_hex is None:
                return
            ct = ask_hex("  Ciphertext (32 hex): ", 32, default[1] if default else None)
            if ct is None:
                return
            tag = ask_hex("  Tag : ", 64, default[2] if default else None)
            if tag is None:
                return
        else:
            r_hex, ct, tag = pkg
        print(">> Receiver FPGA: validate R, S = d*R, derive keys, verify tag, decrypt ...")
        pt = fpga_decrypt(self.ser, r_hex, ct, tag)
        if pt is not None:
            print("[SUCCESS] Tag verified, decryption done")
            show_plain(pt)
            print()
        return pt

    # ---- sender ----
    def set_recipient(self):
        print("Recipient PUBLIC key (the sender has no access to the private key).")
        if self.pub:
            print("  Press Enter at the first prompt to use the key published by the receiver.")
        sx = input("  Qx : ").strip().lower()
        if not sx and self.pub:
            q = self.pub
        else:
            sx = sx[2:] if sx.startswith("0x") else sx
            sy = input("  Qy : ").strip().lower()
            sy = sy[2:] if sy.startswith("0x") else sy
            if not (is_hex(sx, 64) and is_hex(sy, 64)):
                print("[ERROR] Qx and Qy must each be 64 hex characters.\n")
                return
            q = (int(sx, 16), int(sy, 16))
        if not on_curve(q):
            print("[ERROR] (Qx, Qy) is not a point on secp256k1.\n")
            return
        if fpga_set_recipient(self.ser, q):
            self.recipient = q
            print("[OK] recipient public key loaded into the sender registers.\n")

    def encrypt(self, pt_hex=None, ks=None):
        if self.recipient is None:
            print("[ERROR] Set the recipient public key first (option 3).\n")
            return None
        if pt_hex is None:
            pt_hex = pt_from_text(input("Plaintext (32 hex chars, or up to 16 characters of text): "))
            if pt_hex is None:
                return None
        if ks is None:
            ks = ask_scalar("Sender private key ks : ")
            if ks is None:
                return None
        print(">> Sender FPGA: validate Q, R = ks*G, S = ks*Q, derive keys, AES, HMAC ...")
        out = fpga_encrypt(self.ser, ks, pt_hex)
        if out is None:
            return None
        r_hex, ct, tag = out
        self.package = out
        print("[SUCCESS] Encryption done - send this package to the receiver:")
        print(f"   R  (= ks*G, sender public value): {r_hex}")
        print(f"   Ciphertext:                {ct}")
        print(f"   Tag (HMAC-SHA256):         {tag}")
        sw_check_encrypt(ks, self.recipient, pt_hex, r_hex, ct, tag)
        print()
        return out

    # ---- guided demo ----
    def demo(self):
        print("\n=== Guided ECIES demo: sender -> receiver ===\n")
        print("1) RECEIVER key pair (private kr stays on the receiver):")
        kr = ask_scalar("   Receiver private key kr : ")
        if kr is None:
            return
        ks = ask_scalar("   Sender private key ks   : ")
        if ks is None:
            return
        if not fpga_set_private(self.ser, kr):
            return
        self.kr = kr
        self.read_public()
        if self.pub is None:
            return
        print("2) SENDER learns only the public key Q:")
        if not on_curve(self.pub) or not fpga_set_recipient(self.ser, self.pub):
            return
        self.recipient = self.pub
        txt = input("   Message to send (<=16 chars, Enter = 'HELLO FPGA ECC'): ").strip() or "HELLO FPGA ECC"
        pt_hex = pt_from_text(txt)
        if pt_hex is None:
            return
        print("\n3) SENDER encrypts using ks:")
        pkg = self.encrypt(pt_hex, ks)
        if pkg is None:
            return
        print("4) RECEIVER decrypts using only kr and the package:")
        pt = self.decrypt(pkg)
        print(f"   Round trip {'OK' if pt == pt_hex else 'FAILED'}\n")

        print("5) Attack checks:")
        r_hex, ct, tag = pkg
        flipped = f"{int(tag, 16) ^ 1:064x}"
        print("   a) one bit of the tag flipped:")
        report_error(transact(self.ser, f"R{r_hex}{ct}{flipped}\n"))
        print("   b) R replaced by a point that is not on the curve:")
        bad_r = r_hex[:64] + f"{(int(r_hex[64:], 16) + 1) % P:064x}"
        report_error(transact(self.ser, f"R{bad_r}{ct}{tag}\n"))
        print("   c) a different receiver (wrong private key) tries to decrypt:")
        wrong = kr + 1 if kr + 1 < N else kr - 1
        fpga_set_private(self.ser, wrong)
        report_error(transact(self.ser, f"R{r_hex}{ct}{tag}\n"))
        fpga_set_private(self.ser, kr)                 # restore the real receiver key
        print("   (receiver key kr restored on the FPGA)\n")


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PORT

    print("==================================================")
    print(" FPGA ECIES Accelerator (secp256k1 + AES + HMAC)")
    print("==================================================\n")
    print("Available ports:")
    show_ports()
    print()

    ser = open_port(port)
    if ser is None:
        return

    with ser:
        print(f"[OK] Connected to {port} at {BAUD_RATE} baud\n")
        s = Session(ser)

        while True:
            print("Select action:")
            print("  RECEIVER                              SENDER")
            print("   1) Set private key d, get public Q    3) Set recipient public key Q")
            print("   2) Show public key Q (from FPGA)      4) Encrypt a message")
            print("   5) Decrypt a message (R, CT, TAG)")
            print("   6) Guided demo (sender -> receiver round trip + attack checks)")
            print("   q) Quit")
            choice = input("Choice: ").strip().lower()
            print()
            if choice == "q":
                break
            elif choice == "1":
                s.set_private()
            elif choice == "2":
                s.read_public()
            elif choice == "3":
                s.set_recipient()
            elif choice == "4":
                s.encrypt()
            elif choice == "5":
                s.decrypt()
            elif choice == "6":
                s.demo()


if __name__ == "__main__":
    main()
