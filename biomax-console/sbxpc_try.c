#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <oleauto.h>

/* One-call-at-a-time diagnostic against device 604 (EBKN, SBXPCDLL.dll).
 * Each mode is run as its own short-lived process under `timeout` so a call
 * that blocks forever inside the DLL costs one process, not the session.
 *
 * modes:
 *   name      _GetUserName(deviceKind, machine, enroll, eMachine, BSTR* out)
 *   enroll1   _GetEnrollData1(machine, enroll, backup, int*, u8**, int*)
 *   enroll    _GetEnrollData(machine, enroll, eMachine, backup, int*, u8**, int*)
 *   time      _GetDeviceTime(machine, y,m,d,h,mi,s,dow)
 *   privilege _ModifyPrivilege is NOT called here - read-only diagnostic
 */

#define BUFSZ 65536

typedef unsigned char u8;
typedef u8 (__stdcall *ConnectTcpip_t)(int, BSTR *, int, int);
typedef void (__stdcall *Disconnect_t)(int);
typedef u8 (__stdcall *GetLastError_t)(int, int *);
typedef u8 (__stdcall *EnableDevice_t)(int, u8);
typedef u8 (__stdcall *GetUserName_t)(int, int, int, int, BSTR *);
typedef u8 (__stdcall *GetEnrollData1_t)(int, int, int, int *, u8 **, int *);
typedef u8 (__stdcall *GetEnrollData_t)(int, int, int, int, int *, u8 **, int *);
typedef u8 (__stdcall *GetDeviceTime_t)(int, int *, int *, int *, int *, int *, int *, int *);
typedef u8 (__stdcall *GetDeviceStatus_t)(int, int, unsigned int *);

/* _GetDeviceStatus indices, from the vendor sample's frmSystemInfo.cs */
static const char *STATUS_NAMES[] = {
    "", "manager_count", "user_count", "fp_count", "password_count",
    "slog_count", "glog_count", "card_count", "alarm_status", "face_count",
    "slog_unread", "glog_unread"
};

static BSTR bstr_from_ascii(const char *s) {
    int n = MultiByteToWideChar(CP_ACP, 0, s, -1, NULL, 0);
    WCHAR *w = (WCHAR *)malloc(n * sizeof(WCHAR));
    MultiByteToWideChar(CP_ACP, 0, s, -1, w, n);
    BSTR b = SysAllocString(w);
    free(w);
    return b;
}

static void report(u8 *buf, int cap) {
    int touched = cap, nonzero = 0, i;
    while (touched > 0 && buf[touched - 1] == 0xCD) touched--;
    for (i = 0; i < touched; i++) if (buf[i]) nonzero++;
    printf("TOUCHED %d nonzero=%d\n", touched, nonzero);
    int show = touched < 96 ? touched : 96;
    printf("HEAD ");
    for (i = 0; i < show; i++) printf("%02X", buf[i]);
    printf("\n");
}

int main(int argc, char **argv) {
    if (argc < 4) {
        printf("usage: sbxpc_try <ip> <mode> <enrollNo> [backupNo=0]\n");
        return 1;
    }
    const char *ip = argv[1];
    const char *mode = argv[2];
    int enroll = atoi(argv[3]);
    int backup = (argc >= 5) ? atoi(argv[4]) : 0;

    HMODULE dll = LoadLibraryA("SBXPCDLL.dll");
    if (!dll) { printf("LOADFAIL\n"); return 1; }

    ConnectTcpip_t ConnectTcpip = (ConnectTcpip_t)GetProcAddress(dll, "_ConnectTcpip");
    Disconnect_t Disconnect = (Disconnect_t)GetProcAddress(dll, "_Disconnect");
    GetLastError_t SbGetLastError = (GetLastError_t)GetProcAddress(dll, "_GetLastError");
    EnableDevice_t EnableDevice = (EnableDevice_t)GetProcAddress(dll, "_EnableDevice");

    BSTR bip = bstr_from_ascii(ip);
    u8 ok = ConnectTcpip(1, &bip, 5005, 0);
    SysFreeString(bip);
    printf("CONNECT %d\n", (int)ok);
    fflush(stdout);
    if (!ok) return 2;

    printf("DISABLE %d\n", (int)EnableDevice(1, 0));
    fflush(stdout);

    u8 *buf = (u8 *)malloc(BUFSZ);
    memset(buf, 0xCD, BUFSZ);
    int priv = -1, pwd = -1;
    u8 r = 0;

    if (!strcmp(mode, "name")) {
        GetUserName_t f = (GetUserName_t)GetProcAddress(dll, "_GetUserName");
        BSTR nm = NULL;
        printf("CALL _GetUserName\n"); fflush(stdout);
        r = f(0, 1, enroll, 1, &nm);
        printf("RET %d name=%ls\n", (int)r, nm ? nm : L"<null>");
    } else if (!strcmp(mode, "enroll1")) {
        GetEnrollData1_t f = (GetEnrollData1_t)GetProcAddress(dll, "_GetEnrollData1");
        u8 *p = buf;
        printf("CALL _GetEnrollData1 backup=%d\n", backup); fflush(stdout);
        r = f(1, enroll, backup, &priv, &p, &pwd);
        printf("RET %d priv=%d pwd=%d\n", (int)r, priv, pwd);
        if (r) report(buf, BUFSZ);
    } else if (!strcmp(mode, "enroll")) {
        GetEnrollData_t f = (GetEnrollData_t)GetProcAddress(dll, "_GetEnrollData");
        u8 *p = buf;
        printf("CALL _GetEnrollData backup=%d\n", backup); fflush(stdout);
        r = f(1, enroll, 1, backup, &priv, &p, &pwd);
        printf("RET %d priv=%d pwd=%d ptr_moved=%d\n",
               (int)r, priv, pwd, (int)(p != buf));
        if (r) {
            report(buf, BUFSZ);
            if (p != buf && p) {
                /* DLL handed back its own buffer instead of filling ours */
                int i;
                printf("OUTPTR_HEAD ");
                for (i = 0; i < 96; i++) printf("%02X", p[i]);
                printf("\n");
            }
        }
    } else if (!strcmp(mode, "time")) {
        GetDeviceTime_t f = (GetDeviceTime_t)GetProcAddress(dll, "_GetDeviceTime");
        int y = 0, mo = 0, d = 0, h = 0, mi = 0, s = 0, dow = 0;
        printf("CALL _GetDeviceTime\n"); fflush(stdout);
        r = f(1, &y, &mo, &d, &h, &mi, &s, &dow);
        printf("RET %d %04d-%02d-%02d %02d:%02d:%02d dow=%d\n", (int)r, y, mo, d, h, mi, s, dow);
    } else if (!strcmp(mode, "status")) {
        GetDeviceStatus_t f = (GetDeviceStatus_t)GetProcAddress(dll, "_GetDeviceStatus");
        int i;
        r = 1;
        for (i = 1; i <= 11; i++) {
            unsigned int v = 0;
            u8 sr = f(1, i, &v);
            printf("STATUS %d %s = %u (ret %d)\n", i, STATUS_NAMES[i], v, (int)sr);
            fflush(stdout);
        }
    } else {
        printf("UNKNOWN_MODE\n");
    }

    if (!r && SbGetLastError) {
        int err = -1;
        SbGetLastError(1, &err);
        printf("LASTERROR %d\n", err);
    }

    EnableDevice(1, 1);
    Disconnect(1);
    free(buf);
    return 0;
}
