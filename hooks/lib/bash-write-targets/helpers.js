"use strict";

// True if the token looks like a variable expansion or command substitution
// that we cannot statically resolve.
function isUnresolvableToken(tok) {
  return /[$`]|\$\(|>\(/.test(tok);
}

module.exports = { isUnresolvableToken };
