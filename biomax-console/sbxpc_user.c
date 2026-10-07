#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <oleauto.h>

/* User create/delete on device 604 (MORX mBio-M18 / EBKN A30C) via the vendor
 * SBXPCDLL.dll under Wine - the same bridge pattern fk_push.exe / fk_delete.exe
 * already use for the FK623 devices, just against the other SDK.
 *
 * Verbs:
 *   push   <ip> <enrollNo> <name>   -> _SetUserName1
 *   delete <ip> <enrollNo>          -> _DeleteEnrollData over every slot, then blank the name
 *
 * Signatures from the vendor C# wrapper (all __stdcall, leading underscore):
 *   byte _ConnectTcpip(int machineNo, BSTR* ip, int port, int password)
 *   byte _EnableDevice(int machineNo, byte flag)
 *   byte _SetUserName1(int machineNo, int enrollNo, BSTR* name)
 *   byte _DeleteEnrollData(int machineNo, int enrollNo, int eMachineNo, int backupNo)
 *   byte _GetLastError(int machineNo, int* code)
 *   void _Disconnect(int machineNo)
 *
 * The vendor GUI wraps every user-management call in _EnableDevice(0)/(1); without
 * the disable the DLL blocks. _EmptyEnrollData (wipe every user) is deliberately
 * never referenced here.
 *
 * Slot numbering on this firmware: 0-9 fingerprints, 11 card, 15 password, and 50
 * has been observed in _GetAllUserID output, so the delete sweep covers it too. */

typedef unsigned char u8;
typedef u8 (__stdcall *ConnectTcpip_t)(int, BSTR *, int, int);
typedef void (__stdcall *Disconnect_t)(int);
typedef u8 (__stdcall *GetLastError_t)(int, int *);
typedef u8 (__stdcall *EnableDevice_t)(int, u8);
typedef u8 (__stdcall *SetUserName1_t)(int, int, BSTR *);
typedef u8 (__stdcall *DeleteEnrollData_t)(int, int, int, int);

static const int DELETE_SLOTS[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 15, 50};
#define DELETE_SLOT_COUNT ((int)(sizeof(DELETE_SLOTS) / sizeof(DELETE_SLOTS[0])))

static BSTR bstr_from_utf8(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    WCHAR *w = (WCHAR *)malloc(n * sizeof(WCHAR));
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    BSTR b = SysAllocString(w);
    free(w);
    return b;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        printf("usage: sbxpc_user push <ip> <enrollNo> <name>\n");
        printf("       sbxpc_user delete <ip> <enrollNo>\n");
        return 1;
    }
    const char *verb = argv[1];
    const char *ip = argv[2];
    int enroll = atoi(argv[3]);
    const char *name = (argc >= 5) ? argv[4] : "";

    int is_push = !strcmp(verb, "push");
    int is_delete = !strcmp(verb, "delete");
    if (!is_push && !is_delete) { printf("BAD_VERB\n"); return 1; }
    if (is_push && argc < 5) { printf("NAME_REQUIRED\n"); return 1; }
    if (enroll <= 0) { printf("BAD_ENROLL\n"); return 1; }

    HMODULE dll = LoadLibraryA("SBXPCDLL.dll");
    if (!dll) { printf("LOADFAIL %lu\n", (unsigned long)GetLastError()); return 1; }

    ConnectTcpip_t ConnectTcpip = (ConnectTcpip_t)GetProcAddress(dll, "_ConnectTcpip");
    Disconnect_t Disconnect = (Disconnect_t)GetProcAddress(dll, "_Disconnect");
    GetLastError_t SbGetLastError = (GetLastError_t)GetProcAddress(dll, "_GetLastError");
    EnableDevice_t EnableDevice = (EnableDevice_t)GetProcAddress(dll, "_EnableDevice");
    SetUserName1_t SetUserName1 = (SetUserName1_t)GetProcAddress(dll, "_SetUserName1");
    DeleteEnrollData_t DeleteEnrollData = (DeleteEnrollData_t)GetProcAddress(dll, "_DeleteEnrollData");

    if (!ConnectTcpip || !Disconnect || !EnableDevice || !SetUserName1 || !DeleteEnrollData) {
        printf("MISSING_EXPORT\n");
        return 1;
    }

    BSTR bip = bstr_from_utf8(ip);
    u8 ok = ConnectTcpip(1, &bip, 5005, 0);
    SysFreeString(bip);
    printf("CONNECT %d\n", (int)ok);
    fflush(stdout);
    if (!ok) return 2;

    printf("DISABLE %d\n", (int)EnableDevice(1, 0));
    fflush(stdout);

    int rc = 0;
    if (is_push) {
        BSTR bname = bstr_from_utf8(name);
        u8 r = SetUserName1(1, enroll, &bname);
        SysFreeString(bname);
        printf("SETNAME %d\n", (int)r);
        if (!r && SbGetLastError) {
            int err = -1;
            SbGetLastError(1, &err);
            printf("LASTERROR %d\n", err);
        }
        rc = r ? 0 : 3;
    } else {
        int i, deleted = 0;
        for (i = 0; i < DELETE_SLOT_COUNT; i++) {
            u8 r = DeleteEnrollData(1, enroll, 1, DELETE_SLOTS[i]);
            printf("DELETE %d %d\n", DELETE_SLOTS[i], (int)r);
            fflush(stdout);
            if (r) deleted++;
        }
        /* A console-created user may have no biometric data at all, so blanking
         * the name is what actually makes them disappear from the device list. */
        BSTR blank = bstr_from_utf8("");
        u8 cr = SetUserName1(1, enroll, &blank);
        SysFreeString(blank);
        printf("CLEARNAME %d\n", (int)cr);
        printf("TOTAL_DELETED %d\n", deleted);
        rc = (deleted > 0 || cr) ? 0 : 3;
    }

    EnableDevice(1, 1);
    Disconnect(1);
    return rc;
}
