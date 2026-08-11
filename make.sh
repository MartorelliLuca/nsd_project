#!/usr/bin/env bash
set -eu
./deploy_init.sh
./run_init_all.sh
./frr_run.sh
./openvpn_run.sh