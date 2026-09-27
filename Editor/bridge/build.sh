#!/bin/sh
set -eu

x86_64-w64-mingw32-gcc \
	-municode \
	-O2 \
	-Wall \
	-Wextra \
	-Werror \
	-static \
	-s \
	-o unrealed-send.exe \
	unrealed-send.c
