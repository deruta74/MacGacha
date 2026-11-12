/* SPDX-License-Identifier: GPL-3.0-only */
/* MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). */
#include <windows.h>
#include <stdio.h>
static int CALLBACK count_font(const LOGFONTA *font,const TEXTMETRICA *metrics,DWORD type,LPARAM count){(*(int *)count)++;return 1;}
int main(void){HDC dc=CreateCompatibleDC(NULL);LOGFONTA lf={0};TEXTMETRICA tm;int count=0;lf.lfCharSet=DEFAULT_CHARSET;if(!dc)return 1;EnumFontFamiliesExA(dc,&lf,count_font,(LPARAM)&count,0);HFONT font=CreateFontA(-18,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,0,0,0,0,"Arial");HGDIOBJ old=SelectObject(dc,font);int ok=GetTextMetricsA(dc,&tm);printf("font_families=%d text_metrics=%d height=%ld\n",count,ok,ok?tm.tmHeight:0L);SelectObject(dc,old);DeleteObject(font);DeleteDC(dc);return !(count>0&&ok&&tm.tmHeight>0);}
