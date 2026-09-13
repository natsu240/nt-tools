#!/usr/bin/env bash
# 計画書そのもののパス判定。
#
# deny-plan-decision-gate.sh と deny-plan-verification-record.sh が共有する。各スクリプトに書き写すな。片方だけ直すと、一方は止めるのに一方は素通しする。

# plans/ 配下のパスなら 0 を返す。
is_plan_file_path() {
  [[ "$1" == */plans/* ]]
}
