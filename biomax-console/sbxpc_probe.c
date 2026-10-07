#include <stdio.h>
#include <stdlib.h>
#include <windows.h>
#include <oleauto.h>

/* Probe for the EBKN/Realand command channel on device 604 (MORX mBio-M18,
 * TerminalType A30C) via the vendor SBXPCDLL.dll.
 *
 * Signatures taken from the vendor C# wrapper (SBXPCDLL.cs), all __stdcall
 * ("CallingConvention.Winapi") and exported with a leading underscore:
 *   byte _ConnectTcpip(int machineNo, BSTR* ip, int port, int password)
 *   byte _GetSerialNumber(int machineNo, BSTR* out)
 *   byte _ReadAllUserID(int machineNo)
 *   byte _GetAllUserID(int machineNo, int* enroll, int* emachine,
 *                      int* backup, int* privilege, int* enable)
 *   byte _GetLastError(int machineNo, int* errorCode)
 *   void _Disconnect(int machineNo)
 *
 * The C# side builds the IP string with Marshal.StringToBSTR and passes it by
 * reference, so the parameter is a BSTR* (pointer to the OLE string), not a
 * plain char*. */

typedef unsigned char u8;
typedef u8 (__stdcall *ConnectTcpip_t)(int, BSTR *, int, int);
typedef void (__stdcall *Disconnect_t)(int);
typedef u8 (__stdcall *GetLastError_t)(int, int *);
typedef u8 (__stdcall *GetSerialNumber_t)(int, BSTR *);
typedef u8 (__stdcall *ReadAllUserID_t)(int);
typedef u8 (__stdcall *GetAllUserID_t)(int, int *, int *, int *, int *, int *);

static BSTR bstr_from_ascii(const char *s) {
    int n = MultiByteToWideChar(CP_ACP, 0, s, -1, NULL, 0);
    WCHAR *w = (WCHAR *)malloc(n * sizeof(WCHAR));
    MultiByteToWideChar(CP_ACP, 0, s, -1, w, n);
    BSTR b = SysAllocString(w);
    free(w);
    return b;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        printf("usage: sbxpc_probe <ip> [port=5005] [password=0] [machineNo=1]\n");
        return 1;
    }
    const char *ip = argv[1];
    int port = (argc >= 3) ? atoi(argv[2]) : 5005;
    int password = (argc >= 4) ? atoi(argv[3]) : 0;
    int machine = (argc >= 5) ? atoi(argv[4]) : 1;

    HMODULE dll = LoadLibraryA("SBXPCDLL.dll");
    if (!dll) { printf("LOADFAIL %lu\n", (unsigned long)GetLastError()); return 1; }

    ConnectTcpip_t ConnectTcpip = (ConnectTcpip_t)GetProcAddress(dll, "_ConnectTcpip");
    Disconnect_t Disconnect = (Disconnect_t)GetProcAddress(dll, "_Disconnect");
    GetLastError_t SbGetLastError = (GetLastError_t)GetProcAddress(dll, "_GetLastError");
    GetSerialNumber_t GetSerialNumber = (GetSerialNumber_t)GetProcAddress(dll, "_GetSerialNumber");
    ReadAllUserID_t ReadAllUserID = (ReadAllUserID_t)GetProcAddress(dll, "_ReadAllUserID");
    GetAllUserID_t GetAllUserID = (GetAllUserID_t)GetProcAddress(dll, "_GetAllUserID");

    if (!ConnectTcpip || !Disconnect || !ReadAllUserID || !GetAllUserID) {
        printf("MISSING_EXPORT\n");
        return 1;
    }

    BSTR bip = bstr_from_ascii(ip);
    u8 ok = ConnectTcpip(machine, &bip, port, password);
    printf("CONNECT %s:%d pwd=%d machine=%d -> %d\n", ip, port, password, machine, (int)ok);
    SysFreeString(bip);

    if (!ok) {
        int err = -1;
        if (SbGetLastError) { SbGetLastError(machine, &err); printf("LASTERROR %d\n", err); }
        return 2;
    }

    if (GetSerialNumber) {
        BSTR sn = NULL;
        if (GetSerialNumber(machine, &sn) && sn) {
            printf("SERIAL %ls\n", sn);
            SysFreeString(sn);
        } else {
            printf("SERIAL <none>\n");
        }
    }

    if (!ReadAllUserID(machine)) {
        int err = -1;
        if (SbGetLastError) SbGetLastError(machine, &err);
        printf("READALLUSERID_FAIL err=%d\n", err);
        Disconnect(machine);
        return 3;
    }

    int count = 0;
    while (count < 20000) {
        int enroll = -1, emachine = -1, backup = -1, priv = -1, enable = -1;
        if (!GetAllUserID(machine, &enroll, &emachine, &backup, &priv, &enable)) break;
        printf("USER|%d|%d|%d|%d|%d\n", enroll, emachine, backup, priv, enable);
        count++;
    }
    printf("TOTAL %d\n", count);

    Disconnect(machine);
    return 0;
}
