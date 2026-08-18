#!/usr/bin/env bash
# THROWAWAY — go-kure/.github#68 live acceptance spike. Not merged to main.
set -eu

cleanup_user_dir() {
  local target=$1
  rm -rf $target/*
}

cleanup_user_dir "$1"
