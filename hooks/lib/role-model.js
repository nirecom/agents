// Subagent model routing: maps a role (reviewer / producer-high / producer-low /
// alert) to the .env key that selects its model and to that role's default.
// ROLE_TABLE is the single owner of the defaults; value resolution is delegated
// to load-env.js resolveConfigVar (the same rule bin/get-config-var uses).
// Only ALLOWED_MODEL_ALIASES may reach a prompt; anything else falls back to the
// role default, so a .env value can never inject arbitrary text.

const ROLE_TABLE = Object.freeze({
  reviewer: Object.freeze({ key: "MODEL_REVIEWER", default: "opus" }),
  "producer-high": Object.freeze({ key: "MODEL_PRODUCER_HIGH", default: "opus" }),
  "producer-low": Object.freeze({ key: "MODEL_PRODUCER_LOW", default: "sonnet" }),
  alert: Object.freeze({ key: "MODEL_ALERT", default: "sonnet" }),
});

const ALLOWED_MODEL_ALIASES = Object.freeze(["opus", "sonnet", "haiku"]);

function lookupRole(role) {
  if (!Object.prototype.hasOwnProperty.call(ROLE_TABLE, role)) {
    throw new TypeError(`role-model: unknown role "${String(role)}"`);
  }
  return ROLE_TABLE[role];
}

function resolveRoleModel(role) {
  const entry = lookupRole(role);
  let raw;
  try {
    raw = require("./load-env").resolveConfigVar(entry.key, entry.default).value;
  } catch (_) {
    raw = entry.default;
  }
  const normalized = String(raw).trim().toLowerCase();
  if (ALLOWED_MODEL_ALIASES.includes(normalized)) {
    return { model: normalized, key: entry.key, invalid: false };
  }
  return { model: entry.default, key: entry.key, invalid: true };
}

// Anything but "low" routes to producer-high (undecidable fails high).
function modelForLevel(level) {
  return resolveRoleModel(level === "low" ? "producer-low" : "producer-high").model;
}

function formatAgentModelLine(role) {
  return `Subagent model: pass model: "${resolveRoleModel(role).model}" to the Agent tool.`;
}

module.exports = {
  ROLE_TABLE,
  ALLOWED_MODEL_ALIASES,
  resolveRoleModel,
  modelForLevel,
  formatAgentModelLine,
};
