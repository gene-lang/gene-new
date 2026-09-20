## Hosts for tests of the version-1 policy path; never use compatibility grants.
import gene/[capabilities, fs_capabilities, printer, types, vm]

proc newFilesystemPolicyApp*(root: string, capability = "fs/Read"): Application =
  result = newApplication(root)
  let row = result.capabilities.normalizeCapabilityRow(readCapabilityLiteral(
    "[(" & capability & " " & newStr(root).print() & ")]", cuGrant,
    CapabilitySourceContext()), cuGrant)
  let grant = result.filesystemCapabilities.initializeFilesystemGrant(
    row.entries[0].policy)
  result.setRootCapabilities(result.capabilities.newPolicyContext([grant]))
