#!/usr/bin/env bash
set -eu
./scripts/deploy_init.sh
./scripts/ebpf.sh
./scripts/run_init_all.sh
./scripts/frr_run.sh
./scripts/openvpn_run.sh