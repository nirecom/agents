// Pure credential-path detection. Consumer: hooks/block-credentials.js.
"use strict";

const { checkBashCommand } = require("./command-parser");
const { isUnderAnyRoot, globMatchesUnder } = require("./path-match");

// CREDENTIALS_TABLE — single source of truth for protected paths.
// Entry shape:
//   root:               primary ~/... path.
//   extraLiteralRoots?: additional absolute paths. Each family adds /root/<tail> (same path as
//                       root with "~/" stripped) so root-owned container paths are covered symmetrically.
//   displayName:        human-readable name (reserved for future per-family msgs).
const CREDENTIALS_TABLE = [
  { root: "~/.ssh",                               extraLiteralRoots: ["/root/.ssh"],                              displayName: "SSH keys" },
  { root: "~/.gnupg",                             extraLiteralRoots: ["/root/.gnupg"],                            displayName: "GnuPG keyring" },
  { root: "~/.aws",                               extraLiteralRoots: ["/root/.aws"],                              displayName: "AWS credentials" },
  { root: "~/.azure",                             extraLiteralRoots: ["/root/.azure"],                            displayName: "Azure credentials" },
  { root: "~/.config/gh",                         extraLiteralRoots: ["/root/.config/gh"],                        displayName: "GitHub CLI config" },
  { root: "~/.config/gcloud",                     extraLiteralRoots: ["/root/.config/gcloud"],                    displayName: "gcloud SDK credentials" },
  { root: "~/.config/op",                         extraLiteralRoots: ["/root/.config/op"],                        displayName: "op CLI config" },
  { root: "~/.git-credentials",                   extraLiteralRoots: ["/root/.git-credentials"],                  displayName: "Git credentials store" },
  { root: "~/.docker/config.json",                extraLiteralRoots: ["/root/.docker/config.json"],               displayName: "Docker config" },
  { root: "~/.kube",                              extraLiteralRoots: ["/root/.kube"],                             displayName: "Kubernetes config" },
  { root: "~/.npmrc",                             extraLiteralRoots: ["/root/.npmrc"],                            displayName: "npm credentials" },
  { root: "~/.pypirc",                            extraLiteralRoots: ["/root/.pypirc"],                           displayName: "PyPI credentials" },
  { root: "~/.gem/credentials",                   extraLiteralRoots: ["/root/.gem/credentials"],                  displayName: "RubyGems credentials" },
  { root: "~/.vault-token",                       extraLiteralRoots: ["/root/.vault-token"],                      displayName: "HashiCorp Vault token" },
  { root: "~/.cargo/credentials.toml",            extraLiteralRoots: ["/root/.cargo/credentials.toml"],           displayName: "Cargo registry credentials" },
  { root: "~/.netrc",                             extraLiteralRoots: ["/root/.netrc"],                            displayName: "netrc credentials" },
  { root: "~/.pgpass",                            extraLiteralRoots: ["/root/.pgpass"],                           displayName: "PostgreSQL password file" },
  { root: "~/.my.cnf",                            extraLiteralRoots: ["/root/.my.cnf"],                           displayName: "MySQL config" },
  { root: "~/.curlrc",                            extraLiteralRoots: ["/root/.curlrc"],                           displayName: "curl credentials" },
  { root: "~/.m2/settings.xml",                   extraLiteralRoots: ["/root/.m2/settings.xml"],                  displayName: "Maven settings" },
  { root: "~/.gradle/gradle.properties",          extraLiteralRoots: ["/root/.gradle/gradle.properties"],         displayName: "Gradle properties" },
  { root: "~/.terraform.d/credentials.tfrc.json", extraLiteralRoots: ["/root/.terraform.d/credentials.tfrc.json"], displayName: "Terraform credentials" },
  { root: "~/.terraformrc",                       extraLiteralRoots: ["/root/.terraformrc"],                      displayName: "Terraform CLI config" },
  { root: "~/.terraform.rc",                      extraLiteralRoots: ["/root/.terraform.rc"],                     displayName: "Terraform CLI config (Windows)" },
];

const ALL_ROOTS = CREDENTIALS_TABLE.map((e) => e.root);
const ALL_LITERAL_ROOTS = CREDENTIALS_TABLE.flatMap((e) => e.extraLiteralRoots || []);

function isCredentialPath(p) {
  return isUnderAnyRoot(p, ALL_ROOTS, ALL_LITERAL_ROOTS);
}

function isCredentialGlobPattern(pattern) {
  return globMatchesUnder(pattern, [...ALL_ROOTS, ...ALL_LITERAL_ROOTS]);
}

// -i deliberately omitted from PATH_FLAGS: collides with sed -i / grep -i / cp -i.
// Positional fallback still catches ssh -i ~/.ssh/key host.
const TEXT_FLAGS = new Set([
  "-m", "--message", "--body", "--title", "--notes", "--description",
  "--subject", "--branch", "--label", "--assignee", "--reviewer",
  "--milestone", "--project", "--head", "--base",
]);
const PATH_FLAGS = new Set([
  "-f", "--file", "-o", "--output", "--input",
  "--from-file", "--to-file", "-T", "--upload-file",
]);
const TEXT_CMDS = new Set(["echo", "printf"]);
const SHELL_BINS = new Set(["bash", "sh", "dash", "zsh", "ksh"]);

function commandTouchesCredentials(command) {
  return checkBashCommand(command, {
    isTargetPath: isCredentialPath,
    textFlags: TEXT_FLAGS,
    pathFlags: PATH_FLAGS,
    textCmds: TEXT_CMDS,
    shellBins: SHELL_BINS,
  });
}

module.exports = {
  CREDENTIALS_TABLE,
  isCredentialPath,
  isCredentialGlobPattern,
  commandTouchesCredentials,
};
