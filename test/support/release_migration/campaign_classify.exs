# C2* S3 release-migration campaign: the private driver's classification step
# (Codex 599d9bcd rulings 1 and 5; authoring only, never run by the
# ordinary suite).
#
# Usage: mix run --no-start --no-compile --no-deps-check campaign_classify.exs OBSERVATIONS RECEIPTS OUT
#
# Reads the driver's two files and decides with
# `SdrAgent.ReleaseMigration.CampaignFacts.classify_text/2` (pure: no
# application start, no database, no process). The rendered classification
# is written to OUT, created exclusively (an existing path is refused) and
# made 0600. Unusable observations print `CLASSIFY-REFUSED observations` and
# exit 2; any exception exits nonzero. In both cases the driver keeps every
# lease (no classification is no release).
alias SdrAgent.ReleaseMigration.CampaignFacts

[observations, receipts, out] = System.argv()

case CampaignFacts.classify_text(File.read!(observations), File.read!(receipts)) do
  {:error, _reason} ->
    :ok = IO.puts("CLASSIFY-REFUSED observations")
    System.halt(2)

  %{} = result ->
    rendered = Enum.map_join(CampaignFacts.render(result), "", &(&1 <> "\n"))
    :ok = File.write(out, rendered, [:exclusive])
    :ok = File.chmod(out, 0o600)
    :ok = IO.puts("CLASSIFIED rc=#{result.rc}")
    System.halt(0)
end
