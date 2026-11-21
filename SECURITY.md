# Security

Report potential security issues privately to the repository maintainer using GitHub private vulnerability reporting when available. Avoid publicly disclosing actionable vulnerabilities until they can be evaluated.

Package installation is a privileged operation when the underlying installer requires it. Review dry-run plans and installer publishers before approving mutations. pkgs is not a security sandbox and does not validate the safety of every package available through external managers.