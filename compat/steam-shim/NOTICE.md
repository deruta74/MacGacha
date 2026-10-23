<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Steam shim notices and binary redistribution decision

**Artifact set: `steam32.exe` and `steam64.exe` only. Both may be redistributed
as binaries in a GitHub release with this notice.** This is a licensing verdict,
not permission to publish: publication still requires the owner's instruction.

**Do not ship `lsteamclient32.dll` or `lsteamclient64.dll`.** They are not produced.
The Steamworks SDK terms below do not establish permission to distribute a
custom DLL compiled from SDK sources outside `redistributable_bin`. No such
DLL, Steamworks header, or SDK source enters the approved launcher artifacts.
If adding them later, stop for a separate licensing decision before producing
or publishing that artifact set.

## Input inventory (applies separately to each launcher)

- ValveSoftware/Proton `proton-10.0-4`, commit
  `e2becb87430ca3ff510d949d9e75fa9b401da489`, `steam_helper/steam.c`:
  BSD-3-Clause, Copyright (c) 2015, 2019, 2020, 2021, 2022 Valve Corporation.
- The independent generated MinGW compatibility header embedded in
  `scripts/build-steam-shim.sh`: BSD-3-Clause, Copyright (c) 2026 deruta74.
  It provides public Win32/NT ABI declarations, a runtime Wine export lookup,
  and diagnostic adapters. The script's GPL license does not cover this
  separately licensed generated header or change the upstream BSD license.
- MinGW-w64 14.0.0 Windows SDK and C runtime headers, plus statically linked
  startup/runtime objects and Windows import libraries: public domain and
  the ZPL-2.1/per-file permissive notices reproduced below. There is no
  Microsoft Windows SDK or proprietary Windows runtime binary in the output.
  Imported system DLLs are supplied by Wine at runtime.
- GCC 16.2.0 built-in C headers, compiler startup objects and `libgcc` support:
  GPL-3.0-or-later with GCC Runtime Library Exception 3.1. These are eligible
  GCC compilations; the exception permits distributing the independent BSD
  module with runtime support. The complete exception is reproduced below.
- **No Wine source/header is compiled.** Wine's Proton-pinned submodule is
  `b8fdff8e1f855b5276ec4ddca0f31b2792554322`; its ABI was consulted for
  `CP_UNIXCP` (65010) and `wine_get_dos_file_name`. The latter remains a real
  runtime lookup, not a stub. No LGPL Wine debugging implementation is linked.
- **No Steamworks SDK source/header is compiled.** In particular none of
  `lsteamclient/`, its generated SDK wrappers, or `unixlib` enters the launchers.

For each artifact, `audit/deps32.d` / `audit/deps64.d` names **every** compiled
header, including transitive SDK headers; `audit/link32.map` / `audit/link64.map`
names every linked startup/archive object; `audit/pe32.txt` / `audit/pe64.txt`
lists every imported DLL. These audit files accompany both clean builds.
The direct SDK headers are `ntstatus.h`, `windows.h`, `winsvc.h`, `winternl.h`,
`shellapi.h`, `shlwapi.h`, and `msi.h`; standard C headers are `stddef.h`,
`stdarg.h`, `wchar.h`, `wctype.h`, `string.h`, `stdio.h`, `limits.h`, `stdbool.h`.

## Complete compiled header inventory

Generated from the dependency files of the verified pinned toolchain. Each
launcher compiles `steam.c` and the generated `include/wine/debug.h` in addition
to the following headers. `GCC` means GCC Runtime Exception 3.1; `MinGW` means
the MinGW public-domain/permissive header and runtime notices below.

Both `steam32.exe` and `steam64.exe`:

```text
GCC limits.h
GCC mm_malloc.h
GCC stdarg.h
GCC stdbool.h
GCC stddef.h
GCC syslimits.h
MinGW _bsd_types.h
MinGW _mingw.h
MinGW _mingw_mac.h
MinGW _mingw_off_t.h
MinGW _mingw_secapi.h
MinGW _mingw_stat64.h
MinGW _mingw_stdarg.h
MinGW _mingw_unicode.h
MinGW _timeval.h
MinGW apiset.h
MinGW apisetcconv.h
MinGW basetsd.h
MinGW bcrypt.h
MinGW bemapiset.h
MinGW cderr.h
MinGW cguid.h
MinGW combaseapi.h
MinGW commdlg.h
MinGW concurrencysal.h
MinGW consoleapi.h
MinGW consoleapi2.h
MinGW consoleapi3.h
MinGW corecrt.h
MinGW corecrt_stdio_config.h
MinGW corecrt_wconio.h
MinGW corecrt_wctype.h
MinGW corecrt_wstdlib.h
MinGW crtdefs.h
MinGW ctype.h
MinGW datetimeapi.h
MinGW dde.h
MinGW ddeml.h
MinGW debugapi.h
MinGW dlgs.h
MinGW dpapi.h
MinGW driverspecs.h
MinGW errhandlingapi.h
MinGW errno.h
MinGW excpt.h
MinGW fibersapi.h
MinGW fileapi.h
MinGW fltwinerror.h
MinGW guiddef.h
MinGW handleapi.h
MinGW heapapi.h
MinGW imm.h
MinGW inaddr.h
MinGW interlockedapi.h
MinGW ioapiset.h
MinGW jobapi.h
MinGW joystickapi.h
MinGW ktmtypes.h
MinGW libloaderapi.h
MinGW limits.h
MinGW lzexpand.h
MinGW malloc.h
MinGW mciapi.h
MinGW mcx.h
MinGW memoryapi.h
MinGW minwinbase.h
MinGW minwindef.h
MinGW mmeapi.h
MinGW mmiscapi.h
MinGW mmiscapi2.h
MinGW mmsyscom.h
MinGW mmsystem.h
MinGW msi.h
MinGW msxml.h
MinGW namedpipeapi.h
MinGW namespaceapi.h
MinGW nb30.h
MinGW ncrypt.h
MinGW ntstatus.h
MinGW oaidl.h
MinGW objbase.h
MinGW objidl.h
MinGW objidlbase.h
MinGW ole2.h
MinGW oleauto.h
MinGW oleidl.h
MinGW playsoundapi.h
MinGW poppack.h
MinGW processenv.h
MinGW processthreadsapi.h
MinGW processtopologyapi.h
MinGW profileapi.h
MinGW propidl.h
MinGW prsht.h
MinGW psdk_inc/_fd_types.h
MinGW psdk_inc/_ip_mreq1.h
MinGW psdk_inc/_ip_types.h
MinGW psdk_inc/_socket_types.h
MinGW psdk_inc/_wsa_errnos.h
MinGW psdk_inc/_wsadata.h
MinGW psdk_inc/_xmitfile.h
MinGW psdk_inc/intrin-impl.h
MinGW pshpack1.h
MinGW pshpack2.h
MinGW pshpack4.h
MinGW pshpack8.h
MinGW realtimeapiset.h
MinGW reason.h
MinGW rpc.h
MinGW rpcasync.h
MinGW rpcdce.h
MinGW rpcdcep.h
MinGW rpcndr.h
MinGW rpcnsi.h
MinGW rpcnsip.h
MinGW rpcnterr.h
MinGW rpcsal.h
MinGW sal.h
MinGW sdkddkver.h
MinGW sec_api/stdio_s.h
MinGW sec_api/stdlib_s.h
MinGW sec_api/stralign_s.h
MinGW sec_api/string_s.h
MinGW sec_api/wchar_s.h
MinGW sec_api/wconio_s.h
MinGW securityappcontainer.h
MinGW securitybaseapi.h
MinGW servprov.h
MinGW shellapi.h
MinGW shlwapi.h
MinGW shtypes.h
MinGW specstrings.h
MinGW stdarg.h
MinGW stddef.h
MinGW stdio.h
MinGW stdlib.h
MinGW stralign.h
MinGW string.h
MinGW stringapiset.h
MinGW swprintf.inl
MinGW synchapi.h
MinGW sysinfoapi.h
MinGW systemtopologyapi.h
MinGW threadpoolapiset.h
MinGW threadpoollegacyapiset.h
MinGW timeapi.h
MinGW timezoneapi.h
MinGW tvout.h
MinGW unknwn.h
MinGW unknwnbase.h
MinGW urlmon.h
MinGW utilapiset.h
MinGW vadefs.h
MinGW virtdisk.h
MinGW wchar.h
MinGW wctype.h
MinGW winapifamily.h
MinGW winbase.h
MinGW wincon.h
MinGW wincontypes.h
MinGW wincrypt.h
MinGW windef.h
MinGW windows.h
MinGW winefs.h
MinGW winerror.h
MinGW wingdi.h
MinGW winioctl.h
MinGW winnetwk.h
MinGW winnls.h
MinGW winnt.h
MinGW winperf.h
MinGW winreg.h
MinGW winscard.h
MinGW winsmcrd.h
MinGW winsock.h
MinGW winspool.h
MinGW winsvc.h
MinGW winternl.h
MinGW winuser.h
MinGW winver.h
MinGW wnnc.h
MinGW wow64apiset.h
MinGW wtypes.h
MinGW wtypesbase.h
```

Additional headers for `steam32.exe`: none.

Additional headers for `steam64.exe`: 

```text
GCC adxintrin.h
GCC ammintrin.h
GCC amxavx512intrin.h
GCC amxbf16intrin.h
GCC amxcomplexintrin.h
GCC amxfp16intrin.h
GCC amxfp8intrin.h
GCC amxint8intrin.h
GCC amxmovrsintrin.h
GCC amxtf32intrin.h
GCC amxtileintrin.h
GCC avx10_2bf16intrin.h
GCC avx10_2convertintrin.h
GCC avx10_2copyintrin.h
GCC avx10_2mediaintrin.h
GCC avx10_2minmaxintrin.h
GCC avx10_2satcvtintrin.h
GCC avx2intrin.h
GCC avx512bf16intrin.h
GCC avx512bf16vlintrin.h
GCC avx512bitalgintrin.h
GCC avx512bitalgvlintrin.h
GCC avx512bmmintrin.h
GCC avx512bmmvlintrin.h
GCC avx512bwintrin.h
GCC avx512cdintrin.h
GCC avx512dqintrin.h
GCC avx512fintrin.h
GCC avx512fp16intrin.h
GCC avx512fp16vlintrin.h
GCC avx512ifmaintrin.h
GCC avx512ifmavlintrin.h
GCC avx512vbmi2intrin.h
GCC avx512vbmi2vlintrin.h
GCC avx512vbmiintrin.h
GCC avx512vbmivlintrin.h
GCC avx512vlbwintrin.h
GCC avx512vldqintrin.h
GCC avx512vlintrin.h
GCC avx512vnniintrin.h
GCC avx512vnnivlintrin.h
GCC avx512vp2intersectintrin.h
GCC avx512vp2intersectvlintrin.h
GCC avx512vpopcntdqintrin.h
GCC avx512vpopcntdqvlintrin.h
GCC avxifmaintrin.h
GCC avxintrin.h
GCC avxneconvertintrin.h
GCC avxvnniint16intrin.h
GCC avxvnniint8intrin.h
GCC avxvnniintrin.h
GCC bmi2intrin.h
GCC bmiintrin.h
GCC cetintrin.h
GCC cldemoteintrin.h
GCC clflushoptintrin.h
GCC clwbintrin.h
GCC clzerointrin.h
GCC cmpccxaddintrin.h
GCC emmintrin.h
GCC enqcmdintrin.h
GCC f16cintrin.h
GCC fma4intrin.h
GCC fmaintrin.h
GCC fxsrintrin.h
GCC gfniintrin.h
GCC hresetintrin.h
GCC ia32intrin.h
GCC immintrin.h
GCC keylockerintrin.h
GCC lwpintrin.h
GCC lzcntintrin.h
GCC mm3dnow.h
GCC mmintrin.h
GCC movdirintrin.h
GCC movrsintrin.h
GCC mwaitintrin.h
GCC mwaitxintrin.h
GCC pconfigintrin.h
GCC pkuintrin.h
GCC pmmintrin.h
GCC popcntintrin.h
GCC prfchiintrin.h
GCC prfchwintrin.h
GCC raointintrin.h
GCC rdseedintrin.h
GCC rtmintrin.h
GCC serializeintrin.h
GCC sgxintrin.h
GCC sha512intrin.h
GCC shaintrin.h
GCC sm3intrin.h
GCC sm4intrin.h
GCC smmintrin.h
GCC tbmintrin.h
GCC tmmintrin.h
GCC tsxldtrkintrin.h
GCC uintrintrin.h
GCC usermsrintrin.h
GCC vaesintrin.h
GCC vpclmulqdqintrin.h
GCC waitpkgintrin.h
GCC wbnoinvdintrin.h
GCC wmmintrin.h
GCC x86gprintrin.h
GCC x86intrin.h
GCC xmmintrin.h
GCC xopintrin.h
GCC xsavecintrin.h
GCC xsaveintrin.h
GCC xsaveoptintrin.h
GCC xsavesintrin.h
GCC xtestintrin.h
```

## Valve steam_helper BSD-3 notice (verbatim)

```text
/*
 * Copyright (c) 2015, 2019, 2020, 2021, 2022 Valve Corporation
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation and/or
 * other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors
 * may be used to endorse or promote products derived from this software without
 * specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
```

The independent compatibility header uses the same three conditions and
disclaimer above, with the copyright line replaced by:
`Copyright (c) 2026 deruta74. All rights reserved.`

## MinGW-w64 license and runtime notices (verbatim)

Source: MinGW-w64 v14.0.0, commit
`9b3dd0125792fe94d16cacdc596dbd42fca1b369`;
release archive SHA-256
`6eaf921d9eb987d3820b364ea9775bc19b965ec81490b6fdd716526c28e1995c`.
The full runtime notice is included conservatively, including notices for
optional runtime objects not selected by these links.

```text
With exception of certain parts that are prominently marked as being
in the Public Domain, BSD, or LGPL this Software is provided under the
Zope Public License (ZPL) Version 2.1.

Copyright (c) 2009 - 2013 by the mingw-w64 project

See the AUTHORS file for the list of contributors to the mingw-w64 project.

This license has been certified as open source. It has also been designated
as GPL compatible by the Free Software Foundation (FSF).

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

   1. Redistributions in source code must retain the accompanying copyright
      notice, this list of conditions, and the following disclaimer.
   2. Redistributions in binary form must reproduce the accompanying
      copyright notice, this list of conditions, and the following disclaimer
      in the documentation and/or other materials provided with the
      distribution.
   3. Names of the copyright holders must not be used to endorse or promote
      products derived from this software without prior written permission
      from the copyright holders.
   4. The right to distribute this software or to use it for any purpose does
      not give you the right to use Servicemarks (sm) or Trademarks (tm) of
      the copyright holders.  Use of them is covered by separate agreement
      with the copyright holders.
   5. If any files are modified, you must cause the modified files to carry
      prominent notices stating that you changed the files and the date of
      any change.

Disclaimer

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY EXPRESSED
OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, 
OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

```

```text
/**
 * DISCLAIMER
 * This file has no copyright assigned and is placed in the Public Domain.
 * This file is part of the mingw-w64 runtime package.
 *
 * The mingw-w64 runtime package and its code is distributed in the hope that it 
 * will be useful but WITHOUT ANY WARRANTY.  ALL WARRANTIES, EXPRESSED OR 
 * IMPLIED ARE HEREBY DISCLAIMED.  This includes but is not limited to 
 * warranties of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 */

```

```text
MinGW-w64 runtime licensing
***************************

This program or library was built using MinGW-w64 and statically
linked against the MinGW-w64 runtime. Some parts of the runtime
are under licenses which require that the copyright and license
notices are included when distributing the code in binary form.
These notices are listed below.


========================
Overall copyright notice
========================

Copyright (c) 2009, 2010, 2011, 2012, 2013 by the mingw-w64 project

This license has been certified as open source. It has also been designated
as GPL compatible by the Free Software Foundation (FSF).

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

   1. Redistributions in source code must retain the accompanying copyright
      notice, this list of conditions, and the following disclaimer.
   2. Redistributions in binary form must reproduce the accompanying
      copyright notice, this list of conditions, and the following disclaimer
      in the documentation and/or other materials provided with the
      distribution.
   3. Names of the copyright holders must not be used to endorse or promote
      products derived from this software without prior written permission
      from the copyright holders.
   4. The right to distribute this software or to use it for any purpose does
      not give you the right to use Servicemarks (sm) or Trademarks (tm) of
      the copyright holders.  Use of them is covered by separate agreement
      with the copyright holders.
   5. If any files are modified, you must cause the modified files to carry
      prominent notices stating that you changed the files and the date of
      any change.

Disclaimer

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY EXPRESSED
OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

======================================== 
getopt, getopt_long, and getop_long_only
======================================== 

Copyright (c) 2002 Todd C. Miller <Todd.Miller@courtesan.com> 
 
Permission to use, copy, modify, and distribute this software for any 
purpose with or without fee is hereby granted, provided that the above 
copyright notice and this permission notice appear in all copies. 
 	 
THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

Sponsored in part by the Defense Advanced Research Projects
Agency (DARPA) and Air Force Research Laboratory, Air Force
Materiel Command, USAF, under agreement number F39502-99-1-0512.

        *       *       *       *       *       *       * 

Copyright (c) 2000 The NetBSD Foundation, Inc.
All rights reserved.

This code is derived from software contributed to The NetBSD Foundation
by Dieter Baron and Thomas Klausner.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
 1. Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE NETBSD FOUNDATION, INC. AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR CONTRIBUTORS
BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.


===============================================================
gdtoa: Converting between IEEE floating point numbers and ASCII
===============================================================

The author of this software is David M. Gay.

Copyright (C) 1997, 1998, 1999, 2000, 2001 by Lucent Technologies
All Rights Reserved

Permission to use, copy, modify, and distribute this software and
its documentation for any purpose and without fee is hereby
granted, provided that the above copyright notice appear in all
copies and that both that the copyright notice and this
permission notice and warranty disclaimer appear in supporting
documentation, and that the name of Lucent or any of its entities
not be used in advertising or publicity pertaining to
distribution of the software without specific, written prior
permission.

LUCENT DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
IN NO EVENT SHALL LUCENT OR ANY OF ITS ENTITIES BE LIABLE FOR ANY
SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER
IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.

        *       *       *       *       *       *       *

The author of this software is David M. Gay.

Copyright (C) 2005 by David M. Gay
All Rights Reserved

Permission to use, copy, modify, and distribute this software and its
documentation for any purpose and without fee is hereby granted,
provided that the above copyright notice appear in all copies and that
both that the copyright notice and this permission notice and warranty
disclaimer appear in supporting documentation, and that the name of
the author or any of his current or former employers not be used in
advertising or publicity pertaining to distribution of the software
without specific, written prior permission.

THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.  IN
NO EVENT SHALL THE AUTHOR OR ANY OF HIS CURRENT OR FORMER EMPLOYERS BE
LIABLE FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY
DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS
SOFTWARE.

        *       *       *       *       *       *       *

The author of this software is David M. Gay.

Copyright (C) 2004 by David M. Gay.
All Rights Reserved
Based on material in the rest of /netlib/fp/gdota.tar.gz,
which is copyright (C) 1998, 2000 by Lucent Technologies.

Permission to use, copy, modify, and distribute this software and
its documentation for any purpose and without fee is hereby
granted, provided that the above copyright notice appear in all
copies and that both that the copyright notice and this
permission notice and warranty disclaimer appear in supporting
documentation, and that the name of Lucent or any of its entities
not be used in advertising or publicity pertaining to
distribution of the software without specific, written prior
permission.

LUCENT DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
IN NO EVENT SHALL LUCENT OR ANY OF ITS ENTITIES BE LIABLE FOR ANY
SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER
IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.


=========================
Parts of the math library
=========================

Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.

Developed at SunSoft, a Sun Microsystems, Inc. business.
Permission to use, copy, modify, and distribute this
software is freely granted, provided that this notice
is preserved.

        *       *       *       *       *       *       *

Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.

Developed at SunPro, a Sun Microsystems, Inc. business.
Permission to use, copy, modify, and distribute this
software is freely granted, provided that this notice
is preserved.

        *       *       *       *       *       *       *

FIXME: Cephes math lib
Copyright (C) 1984-1998 Stephen L. Moshier

It sounds vague, but as to be found at
<http://lists.debian.org/debian-legal/2004/12/msg00295.html>, it gives an
impression that the author could be willing to give an explicit
permission to distribute those files e.g. under a BSD style license. So
probably there is no problem here, although it could be good to get a
permission from the author and then add a license into the Cephes files
in MinGW runtime. At least on follow-up it is marked that debian sees the
version a-like BSD one. As MinGW.org (where those cephes parts are coming
from) distributes them now over 6 years, it should be fine.

=================================================
Some string, memory and time conversion functions
=================================================

Copyright © 2005-2020 Rich Felker, et al.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

===================================
Headers and IDLs imported from Wine
===================================

Some header and IDL files were imported from the Wine project. These files
are prominent maked in source. Their copyright belongs to contributors and
they are distributed under LGPL license.

Disclaimer

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

```

## GCC Runtime Library Exception (verbatim)

The GPL version 3 text is in this repository's `LICENSE`. Exception text from
GCC's `COPYING.RUNTIME`, version 3.1 (31 March 2009):

```text
GCC RUNTIME LIBRARY EXCEPTION

Version 3.1, 31 March 2009

Copyright (C) 2009 Free Software Foundation, Inc. <http://fsf.org/>

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.

This GCC Runtime Library Exception ("Exception") is an additional
permission under section 7 of the GNU General Public License, version
3 ("GPLv3"). It applies to a given file (the "Runtime Library") that
bears a notice placed by the copyright holder of the file stating that
the file is governed by GPLv3 along with this Exception.

When you use GCC to compile a program, GCC may combine portions of
certain GCC header files and runtime libraries with the compiled
program. The purpose of this Exception is to allow compilation of
non-GPL (including proprietary) programs to use, in this way, the
header files and runtime libraries covered by this Exception.

0. Definitions.

A file is an "Independent Module" if it either requires the Runtime
Library for execution after a Compilation Process, or makes use of an
interface provided by the Runtime Library, but is not otherwise based
on the Runtime Library.

"GCC" means a version of the GNU Compiler Collection, with or without
modifications, governed by version 3 (or a specified later version) of
the GNU General Public License (GPL) with the option of using any
subsequent versions published by the FSF.

"GPL-compatible Software" is software whose conditions of propagation,
modification and use would permit combination with GCC in accord with
the license of GCC.

"Target Code" refers to output from any compiler for a real or virtual
target processor architecture, in executable form or suitable for
input to an assembler, loader, linker and/or execution
phase. Notwithstanding that, Target Code does not include data in any
format that is used as a compiler intermediate representation, or used
for producing a compiler intermediate representation.

The "Compilation Process" transforms code entirely represented in
non-intermediate languages designed for human-written code, and/or in
Java Virtual Machine byte code, into Target Code. Thus, for example,
use of source code generators and preprocessors need not be considered
part of the Compilation Process, since the Compilation Process can be
understood as starting with the output of the generators or
preprocessors.

A Compilation Process is "Eligible" if it is done using GCC, alone or
with other GPL-compatible software, or if it is done without using any
work based on GCC. For example, using non-GPL-compatible Software to
optimize any GCC intermediate representations would not qualify as an
Eligible Compilation Process.

1. Grant of Additional Permission.

You have permission to propagate a work of Target Code formed by
combining the Runtime Library with Independent Modules, even if such
propagation would otherwise violate the terms of GPLv3, provided that
all Target Code was generated by Eligible Compilation Processes. You
may then convey such a combination under terms of your choice,
consistent with the licensing of the Independent Modules.

2. No Weakening of GCC Copyleft.

The availability of this Exception does not imply any general
presumption that third-party software is unaffected by the copyleft
requirements of the license of GCC.


```

## Excluded lsteamclient: Steamworks SDK terms (verbatim)

Source: Proton commit above, `lsteamclient/LICENSE`. Section 1.1 limits the
binary distribution grant to `redistributable_bin`; section 1.3 reserves
other rights. This custom Wine/Unix bridge is not an SDK Redistributable.
Consequently it is not cleared for a GitHub binary release. Its PE side also
calls `WINE_UNIX_CALL` and requires `lsteamclient.so`; a PE DLL alone cannot
provide that implementation on macOS. This build makes no fake Steam API DLL.

```text
================ STEAMWORKS SDK license ===================
VALVE, Corp.
SDK LICENSE

This SDK License (the "Agreement") is made by and between you (the "Licensee")
and Valve Corporation, a Washington corporation,(“Valve”) with offices located
at 10400 NE 4th Street, Suite 1400, Bellevue, WA 98004, USA.

THIS DOCUMENT DESCRIBES A CONTRACT BETWEEN YOU AND VALVE. PLEASE READ IT BEFORE
DOWNLOADING OR USING THE STEAMWORKS SOFTWARE DEVELOPMENT KIT (THE “SDK”). BY
DOWNLOADING AND/OR USING THE SDK YOU INDICATE YOUR ACCEPTANCE OF THIS
AGREEMENT. IF YOU DO NOT AGREE, DO NOT DOWNLOAD AND/OR USE THE SDK.

Whereas, Valve is the developer of an online platform titled "Steam" that
provides online distribution services as well as a number of additional online
services designed to be embedded in computer games and application software,
including, but not limited to, user authentication, in-app purchasing and
trading, leaderboards, matchmaking, stats and achievements (the “Steamworks
Services”) and the SDK;

Whereas, Licensee wishes to develop a game or application software designed to
take advantage of the Steamworks Services (the "Licensee Software"); and

Whereas, Licensee wishes to receive, and Valve wishes to disclose to Licensee,
the SDK, and other information as deemed appropriate by Valve, all on the
terms set forth herein;

Now, therefore, in consideration of the mutual promises made herein, the
parties agree as follows:

1. License.

1.1 License Grant. Valve hereby grants Licensee a nonexclusive, royalty-free,
terminable, worldwide, nontransferable license to:

(a) use and locally reproduce the SDK in source code form, solely to develop
the Licensee Software; and

(b) reproduce and distribute the part of the SDK provided inside the folder
named redistributable_bin (the "SDK Redistributables") along with the Licensee
Software in object code form.

1.2 Updates. Valve may from time to time, in its sole discretion, provide
updates, error corrections, and future versions of the SDK to Licensee. Upon
delivery, such updates, error corrections and future versions shall be deemed
part of the SDK, as applicable, under this Agreement.

1.3 Reservation of Rights. Valve reserves all rights not explicitly granted
herein.

2. Ancillary Obligations.

2.1 No obligation to provide services. Nothing herein shall be construed as
establishing an obligation to Valve to provide Steamworks Services or accept
Licensee Software for distribution via Steam.

2.2 Indemnity. Licensee hereby agrees that it is solely responsible for any
and all Licensee Software and Licensee's creation, distribution, and promotion
thereof. Licensee shall defend, indemnify, and hold harmless Valve, its
officers, directors, employees and agents against any and all claims, damages
(including reasonable attorneys’ fees and costs), losses, or liabilities
whatsoever arising out of Licensee's creation, distribution, or promotion of
the Licensee Software.

2.3 Trademarks. Licensee acknowledges and agrees that this Agreement does not
grant Licensee any right to use any trademarks or trade names of Valve or its
licensors. All such marks shall remain the property of the respective owner.
Licensee will refrain from any action or communication that can be incorrectly
interpreted as a cooperation or partnership between Valve and Licensee.

2.4 No reverse engineering. Licensee will not take any steps to reverse
engineer the functionality of the SDK or develop software to replace the SDK's
functionality. If Licensee develops software to interact with the Steamworks
Services, such software shall not communicate with the Steamworks Services
directly but always through the application programming interface (API)
provided by the SDK Redistributables.

3. Term.

3.1 Term. This Agreement shall become effective as of the date Licensee
downloads or installs the SDK. It will continue to apply until terminated by
either Valve or Licensee as set out below.

3.2 Termination. Valve may terminate this Agreement immediately upon written
(including email) notice to Licensee. Licensee may terminate this Agreement at
any time by ceasing Licensees use of the SDK and ending Licensee's
distribution of Licensee Software created using the SDK. Furthermore, the
Agreement will terminate automatically upon Licensee's breach of any term of
this Agreement.

3.3 Survival. Sections 1.3, 2, 3.2, 3.3, and 4-6 shall survive any expiration
or termination of this Agreement.

4. Disclaimer of Warranties; Limitation of Liability

4.1 NO WARRANTIES. THE SDK AND ANY OTHER MATERIAL DOWNLOADED BY LICENSEE IS
PROVIDED “AS IS”. VALVE AND ITS SUPPLIERS DISCLAIM ALL WARRANTIES WITH RESPECT
TO THE SDK, EITHER EXPRESS OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, IMPLIED
WARRANTIES OF MERCHANTABILITY, NON-INFRINGEMENT, TITLE AND FITNESS FOR A
PARTICULAR PURPOSE.

4.2 LIMITATION OF LIABILITY. IN NO EVENT SHALL VALVE OR ITS SUPPLIERS BE
LIABLE FOR ANY SPECIAL, INCIDENTAL, INDIRECT, OR CONSEQUENTIAL DAMAGES
WHATSOEVER (INCLUDING, WITHOUT LIMITATION, DAMAGES FOR LOSS OF BUSINESS
PROFITS, BUSINESS INTERRUPTION, LOSS OF BUSINESS INFORMATION, OR ANY OTHER
PECUNIARY LOSS) ARISING OUT OF THE USE OF OR INABILITY TO USE THE ENGINE
AND/OR THE SDK, EVEN IF VALVE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH
DAMAGES.

5. No Exclusivity.

Neither this Agreement nor the disclosure or receipt of Information shall
constitute or imply any promise to or intention to make any purchase of
products or services by either party or its affiliated companies or any
commitment by either party or its affiliated companies with respect to the
present or future marketing of any product or service or any commitment to
enter into any other business relationship. Except for the license and use
restrictions expressly set forth herein, each party will be free (1) to
pursue, negotiate, and enter into similar relationships with third parties and
(2) to develop, market, and make available similar products and services.
Neither party will be obligated to enter into any other agreement with the
other party by virtue of this Agreement.

6. General.

6.1 Modification. No amendment or modification of this Agreement shall be
valid or binding on the parties unless made in writing and signed on behalf of
both of the parties by their respective duly authorized officers or
representatives.

6.2 Assignment. Licensee may not assign this agreement without the prior
written consent of Valve. Subject to the limitations set forth in this
Agreement, this Agreement will inure to the benefit of and be binding upon the
parties, their successors and assigns.

6.3 Severability. If any provision of this Agreement shall be held by a court
of competent jurisdiction to be illegal, invalid or unenforceable, the
remaining provisions shall remain in full force and effect.

6.4 Governing Law, Jurisdiction and Venue. This Agreement shall be governed by
the laws of the State of Washington. For any claims of any kind arising out of
this Agreement or use of the SDK, each of the parties hereto submits to
exclusive jurisdiction and venue in the state and federal courts sitting in
King County, Washington.

6.5 Entire Agreement. This Agreement constitutes the entire understanding
between the parties hereto and supersedes all previous communications,
representations and understandings, oral or written, between the parties, with
respect to the subject matter of this Agreement.

```
