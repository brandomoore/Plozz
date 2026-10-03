#ifndef PLOZZ_LIBASS_CONFIG_H
#define PLOZZ_LIBASS_CONFIG_H

#if defined(__aarch64__)
#define ARCH_AARCH64 1
#define CONFIG_ASM 1
#define PREFIX 1
#else
#define CONFIG_ASM 0
#endif

#define CONFIG_CORETEXT 1
#define CONFIG_ICONV 1
#define CONFIG_UNIBREAK 1
#define CONFIG_LARGE_TILES 0
#define CONFIG_SOURCEVERSION "0.17.5"
#define HAVE_STRDUP 1
#define HAVE_STRNDUP 1
#define HAVE_ICONV_H 1
#define HAVE_UNISTD_H 1
#define _DARWIN_C_SOURCE 1

#endif
