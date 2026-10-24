/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Wine MR 11824 regression adapted from Michael Nelson's crypt32/tests/msg.c. */
#include <windows.h>
#include <wincrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include "signature-fixture.h"

int main(int argc, char **argv)
{
    HCRYPTMSG msg;
    PCCERT_CONTEXT cert;
    BYTE *blob;
    DWORD size = 0;
    BOOL verified;
    int expected;
    if (argc != 2) return 2;
    expected = atoi(argv[1]);
    msg = CryptMsgOpenToDecode(PKCS_7_ASN_ENCODING, 0, 0, 0, NULL, NULL);
    if (!msg) return 3;
    if (!CryptMsgUpdate(msg, msgWithUnsortedAuthAttrs, sizeof(msgWithUnsortedAuthAttrs), TRUE)) return 4;
    if (!CryptMsgGetParam(msg, CMSG_CERT_PARAM, 0, NULL, &size)) return 5;
    blob = HeapAlloc(GetProcessHeap(), 0, size);
    if (!blob || !CryptMsgGetParam(msg, CMSG_CERT_PARAM, 0, blob, &size)) return 6;
    cert = CertCreateCertificateContext(X509_ASN_ENCODING, blob, size);
    if (!cert) return 7;
    verified = CryptMsgControl(msg, 0, CMSG_CTRL_VERIFY_SIGNATURE, cert->pCertInfo);
    printf("authenticated-attribute-order: verified=%d error=%08lx\n", !!verified, GetLastError());
    CertFreeCertificateContext(cert);
    HeapFree(GetProcessHeap(), 0, blob);
    CryptMsgClose(msg);
    return !!verified == expected ? 0 : 8;
}
