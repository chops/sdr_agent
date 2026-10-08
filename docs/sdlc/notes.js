// Owner notes for the interactive SDLC map: browser storage, a visible
// "not saved" state, and an export bound to the exact data the owner saw.
// Kept separate from index.html so docs/sdlc/check-notes.mjs can test it in
// node without a browser.
(function (root) {
  "use strict";

  function probe(storage) {
    try {
      var k = "__sdlc_probe__";
      storage.setItem(k, "1");
      storage.removeItem(k);
      return true;
    } catch (e) {
      return false;
    }
  }

  // getStorage is a function so a throwing localStorage accessor is caught.
  function createStore(getStorage, key) {
    var storage = null;
    try { storage = getStorage(); } catch (e) { storage = null; }
    var notes = {};
    var api = { available: !!storage && probe(storage), problem: null };
    if (!api.available) api.problem = "unavailable";
    if (api.available) {
      try { notes = JSON.parse(storage.getItem(key) || "{}") || {}; } catch (e) { notes = {}; }
    }
    api.get = function (k) { return notes[k] || ""; };
    api.all = function () { return Object.assign({}, notes); };
    // Returns true only when the note reached browser storage.
    api.set = function (k, v) {
      notes[k] = v;
      if (!api.available) return false;
      try {
        storage.setItem(key, JSON.stringify(notes));
        return true;
      } catch (e) {
        api.available = false;
        api.problem = "write_failed";
        return false;
      }
    };
    return api;
  }

  // FNV-1a over the serialized data: changes whenever any process data changes.
  function fingerprint(data) {
    var s = JSON.stringify(data), h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return ("00000000" + h.toString(16)).slice(-8);
  }

  function storageWarning(store) {
    if (store.available) return "";
    return store.problem === "write_failed"
      ? "Your last note could not be saved in this browser. Notes will be lost when this page reloads. Copy or download them now."
      : "This browser is not saving notes on this page. They will be lost when it reloads. Copy or download them before you leave.";
  }

  function exportText(D, notes, fp) {
    var out = [
      "SDLC map notes",
      "Data revision " + D.meta.revision + " (fingerprint " + fp + "), " + D.meta.version,
      "These notes are feedback, not approvals. Approvals are given in chat and recorded in a gate record.",
      ""
    ];
    var body = 0;
    D.openQuestions.forEach(function (q) {
      var v = String(notes["q:" + q.id] || "").trim();
      if (v) { body++; out.push(q.id + ". " + q.q, "   " + v.replace(/\n/g, "\n   "), ""); }
    });
    D.phases.forEach(function (p) {
      var v = String(notes["phase:" + p.id] || "").trim();
      if (v) { body++; out.push(p.id + " " + p.name + ":", "   " + v.replace(/\n/g, "\n   "), ""); }
    });
    if (!body) out.push("(No notes yet.)");
    return out.join("\n");
  }

  root.SDLCNotes = { createStore: createStore, fingerprint: fingerprint, storageWarning: storageWarning, exportText: exportText };
})(typeof window !== "undefined" ? window : globalThis);
