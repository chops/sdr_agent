// Owner notes for the interactive SDLC map: browser storage, a visible
// "not saved" state, and an export that says which data revision each note
// was written against. Kept separate from index.html so
// docs/sdlc/check-notes.mjs can test it in node without a browser.
//
// Stored format (version 2), one notebook across data revisions:
//   { "version": 2, "notes": { "<field>": { "text", "revision", "fingerprint", "context" } } }
// "context" is the question or phase name as it read when the note was
// written. Version 1 stored plain { "<field>": "<text>" }; those notes are kept
// as legacy notes with no known revision, never relabelled as current.
(function (root) {
  "use strict";

  function canWrite(storage) {
    try {
      var k = "__sdlc_probe__";
      storage.setItem(k, "1");
      storage.removeItem(k);
      return true;
    } catch (e) {
      return false;
    }
  }

  function normalize(parsed) {
    var out = {};
    if (!parsed || typeof parsed !== "object") return out;
    if (parsed.version === 2 && parsed.notes && typeof parsed.notes === "object") {
      Object.keys(parsed.notes).forEach(function (k) {
        var n = parsed.notes[k];
        if (n && typeof n.text === "string") {
          out[k] = { text: n.text, revision: n.revision || null, fingerprint: n.fingerprint || null, context: n.context || null };
        }
      });
      return out;
    }
    Object.keys(parsed).forEach(function (k) {
      if (typeof parsed[k] === "string") out[k] = { text: parsed[k], revision: null, fingerprint: null, context: null };
    });
    return out;
  }

  // getStorage is a function so a throwing localStorage accessor is caught.
  // origin = { revision, fingerprint } of the data the page is showing.
  // Reading and writing are checked separately: a full or read-only store can
  // still return the notes saved earlier, and those must stay visible.
  function createStore(getStorage, key, origin) {
    origin = origin || { revision: null, fingerprint: null };
    var storage = null;
    try { storage = getStorage(); } catch (e) { storage = null; }
    var notes = {};
    var api = { available: false, problem: null, unreadable: null };
    if (!storage) {
      api.problem = "unavailable";
    } else {
      var raw = null;
      try { raw = storage.getItem(key); } catch (e) { api.problem = "read_failed"; }
      if (raw) {
        try {
          notes = normalize(JSON.parse(raw));
        } catch (e) {
          // Keep the unparseable bytes for export, and never write over them.
          api.unreadable = raw;
          api.problem = "corrupt";
        }
      }
      if (!api.problem) {
        api.available = canWrite(storage);
        if (!api.available) api.problem = "write_failed";
      }
    }
    api.get = function (k) { return notes[k] ? notes[k].text : ""; };
    api.entry = function (k) { return notes[k] || null; };
    api.all = function () { return Object.assign({}, notes); };
    // True when the note was written against a different (or unknown) revision.
    api.isStale = function (k) { return !!notes[k] && notes[k].revision !== origin.revision; };
    // Writing a note stamps it with the revision the page is showing. Returns
    // true only when the note reached browser storage.
    api.set = function (k, text, context) {
      notes[k] = { text: text, revision: origin.revision, fingerprint: origin.fingerprint, context: context || null };
      if (!api.available) return false;
      try {
        storage.setItem(key, JSON.stringify({ version: 2, notes: notes }));
        return true;
      } catch (e) {
        api.available = false;
        api.problem = "write_failed";
        return false;
      }
    };
    return api;
  }

  // FNV-1a over the serialized data. A quick check that two copies of the page
  // showed the same data; it is not a security hash and proves nothing about
  // integrity or authorship. The revision and the commit-bound gate record are
  // the authority.
  function fingerprint(data) {
    var s = JSON.stringify(data), h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return ("00000000" + h.toString(16)).slice(-8);
  }

  function storageWarning(store) {
    switch (store.problem) {
      case null: return "";
      case "write_failed":
        return "This browser is not saving new notes on this page. Notes saved earlier are still shown. New notes will be lost when the page reloads, so copy or download them now.";
      case "corrupt":
        return "Notes saved earlier in this browser could not be read. They are kept untouched and included in the export. New notes will not be saved here, so copy or download them before you leave.";
      default:
        return "This browser is not saving notes on this page. They will be lost when it reloads. Copy or download them before you leave.";
    }
  }

  function indent(v) { return "   " + String(v).trim().replace(/\n/g, "\n   "); }

  // Current notes are listed under the current wording. Notes written against
  // another revision, or before revisions were recorded, are listed apart with
  // the wording they answered, so they are never read as current feedback.
  function exportText(D, notes, fp, unreadable) {
    var out = [
      "SDLC map notes",
      "Exported from data revision " + D.meta.revision + " (fingerprint " + fp + "), " + D.meta.version,
      "These notes are feedback, not approvals. Approvals are given in chat and recorded in a gate record.",
      ""
    ];
    var labels = {};
    D.openQuestions.forEach(function (q) { labels["q:" + q.id] = q.id + ". " + q.q; });
    D.phases.forEach(function (p) { labels["phase:" + p.id] = p.id + " " + p.name; });
    var order = Object.keys(labels).concat(Object.keys(notes).filter(function (k) { return !labels[k]; }).sort());
    var current = [], older = [];
    order.forEach(function (k) {
      var n = notes[k];
      if (!n || !String(n.text).trim()) return;
      if (n.revision === D.meta.revision) {
        current.push((labels[k] || n.context || k) + ":", indent(n.text), "");
      } else {
        var origin = n.revision ? "revision " + n.revision + (n.fingerprint ? " (fingerprint " + n.fingerprint + ")" : "") : "an unknown revision (saved before revisions were recorded)";
        older.push((n.context || labels[k] || k) + ":", "   [written against " + origin + "]", indent(n.text), "");
      }
    });
    if (current.length) out = out.concat(current);
    if (older.length) {
      out.push("Older notes, not confirmed for revision " + D.meta.revision + ". The question or phase may have changed since:", "");
      out = out.concat(older);
    }
    if (unreadable) out.push("Saved data this browser could not read (raw):", indent(unreadable), "");
    if (!current.length && !older.length && !unreadable) out.push("(No notes yet.)");
    return out.join("\n");
  }

  root.SDLCNotes = { createStore: createStore, fingerprint: fingerprint, storageWarning: storageWarning, exportText: exportText };
})(typeof window !== "undefined" ? window : globalThis);
