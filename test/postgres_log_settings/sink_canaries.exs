# 5b sink test client entry (plan r2 5.4 as amended by r3-r6 and R6-1).
# Run only by test/postgres_log_settings/sink-test.sh, never by hand:
#
#   MIX_ENV=test mix run --no-start test/postgres_log_settings/sink_canaries.exs --mode ... --out ...
#
# The logic lives in SdrAgent.Test.PostgresLogSinkCanaries (test/support), so
# `mix compile --warnings-as-errors` and Credo check it.
SdrAgent.Test.PostgresLogSinkCanaries.main(System.argv())
