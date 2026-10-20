# Credo's default configuration, with one check disabled.
#
# Credo.Check.Consistency.ExceptionNames infers a project-wide prefix or
# suffix from exception module names. The C3-02 identity-key exceptions
# (SdrAgent.Audit.IdentityKeys.*) are named for their conditions by the
# accepted plan and pinned by its tests (LateAcquisition, PassInconsistent,
# MissingPass, AcquisitionFailed, InvalidKeyValue, NotInTransaction,
# UnscopedTransaction, ScopeConflict), so no shared affix exists and the
# check would flag unrelated exceptions instead.
%{
  configs: [
    %{
      name: "default",
      checks: %{
        disabled: [
          {Credo.Check.Consistency.ExceptionNames, []}
        ]
      }
    }
  ]
}
