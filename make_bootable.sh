#!/usr/bin/env bash
# v1 : FAT16 and FAT32, based on Trammel version
# v2 : exFAT supported. arm.indiana@gmail.com
# v3 : Osx and Linux auto detect device
#
# patch the SD/CF card bootsector to make it bootable on Canon DSLR
# See http://chdk.setepontos.com/index.php/topic,4214.0.html
#     http://en.wikipedia.org/wiki/File_Allocation_Table#Boot_Sector

# usage: make_bootable.sh (card needs to be formatted on camera or have volume name: EOS_DIGITAL)
# exfat_sum.c must bu compiled first

set -euo pipefail

#
# Unmount
#
_unmount() {
  local _DEVICE="${1}"

  echo "Unmounting: ${_DEVICE}"

  if [[ "${OSTYPE}" == darwin* ]]; then
    # OS X
    diskutil unmount "${_DEVICE}"
  elif [[ "${OSTYPE}" == linux* ]]; then
    # Linux
    umount "${_DEVICE}"
  else
    echo >&2 "Error: OSTYPE \"${OSTYPE}\" is not known"
    exit 1
  fi
}

_main() {
  local _DEVICE=""

  # Auto detects the card if formatted incamera before using this script
  if [ -n "${1:-}" ]; then
    _DEVICE="${1}"
    echo "Using device: ${_DEVICE}"
  else
    if _DEVICE=$(mount | grep EOS_DIGITAL | awk '{print $1}'); then
      echo "Found device: ${_DEVICE}"
    fi
  fi

  if [ -z "${_DEVICE}" ]; then
    echo >&2 "No device provided or EOS_DIGITAL card detected."
    echo >&2 "The EOS_DIGITAL card should be mounted before running the script."
    exit 1
  fi

  if ! [ -b "${_DEVICE}" ]; then
    echo >&2 "Device: \"${_DEVICE}\" does not exist."
    exit 1
  fi

  _unmount "${_DEVICE}"

  local _OFFSET1=""
  local _OFFSET2=""
  local _FS=""

  if [ "$(id -u)" != 0 ]; then
    echo >&2 "dd operations require you to have access to the device, run script as root to be sure"
    exit 1
  fi

  # Read the boot sector to determine the filesystem version
  if [ "$(dd if="${_DEVICE}" bs=1 skip=54 count=8 2>/dev/null)" = 'FAT16   ' ]; then
    _OFFSET1=43
    _OFFSET2=64
    _FS='FAT16'
  elif [ "$(dd if="${_DEVICE}" bs=1 skip=82 count=8 2>/dev/null)" = 'FAT32   ' ]; then
    _OFFSET1=71
    _OFFSET2=92
    _FS='FAT32'
  elif [ "$(dd if="${_DEVICE}" bs=1 skip=3 count=8 2>/dev/null)" = 'EXFAT   ' ]; then
    _OFFSET1=130
    _OFFSET2=122
    _FS='EXFAT'
  else
    echo >&2 "Error: ${_DEVICE} is not a FAT16, FAT32 of EXFAT device"
    echo >&2 "Format your card in camera before using this script"
    exit 1
  fi

  echo "Detected filesystem: ${_FS}"

  if [ "${_FS}" = 'EXFAT' ]; then
    if ! [ -f "./exfat_sum" ]; then
      echo "Please compile exfat_sum before continuing"
      echo "g++ -o exfat_sum exfat_sum.c"
      exit 1
    fi
  fi

  echo "Writing EOS_DEVELOP at offset ${_OFFSET1} (Volume label)"
  echo -n EOS_DEVELOP | dd of="${_DEVICE}" bs=1 seek="${_OFFSET1}" count=11

  echo "Writing BOOTDISK at offset ${_OFFSET2} (Boot code)"
  echo -n BOOTDISK | dd of="${_DEVICE}" bs=1 seek="${_OFFSET2}" count=8

  if [ "${_FS}" = 'EXFAT' ]; then
    # write them also in backup VBR, at sector 13
    local _OFFSET1_BACKUP
    _OFFSET1_BACKUP=$((_OFFSET1 + 512 * 12))
    echo "Writing EOS_DEVELOP at offset ${_OFFSET1_BACKUP} (Volume label)"
    echo -n EOS_DEVELOP | dd of="${_DEVICE}" bs=1 seek="${_OFFSET1_BACKUP}" count=11 2>/dev/null

    local _OFFSET2_BACKUP
    _OFFSET2_BACKUP=$((_OFFSET2 + 512 * 12))
    echo "Writing BOOTDISK at offset ${_OFFSET2_BACKUP} (Boot code)"
    echo -n BOOTDISK | dd of="${_DEVICE}" bs=1 seek="${_OFFSET2_BACKUP}" count=8 2>/dev/null

    local _DUMP_FILE=exfat_dump.bin

    echo "Dumping exfat data"
    dd if="${_DEVICE}" of="${_DUMP_FILE}" bs=1 skip=0 count=6144 2>/dev/null

    echo 'Recomputing checksum'
    ./exfat_sum "$_DUMP_FILE"

    # write VBR checksum (from sector 0 to sector 10) at offset 5632 (sector 11) and offset 11776 (sector 23, for backup VBR)
    # checksum sector is stored in $_DUMP_FILE at offset 5632
    echo "Writing VBR checksum"
    dd of="${_DEVICE}" if="${_DUMP_FILE}" bs=1 seek=5632 skip=5632 count=512 2>/dev/null
    dd of="${_DEVICE}" if="${_DUMP_FILE}" bs=1 seek=11776 skip=5632 count=512 2>/dev/null

    rm -f "${_DUMP_FILE}"
  fi

}

###

_main "$@"
