(function () {
  "use strict";

  // Pre-select the Windows tab for Windows visitors; everyone else keeps
  // the macOS/Linux default. Best-effort — falls back silently if the
  // platform can't be determined.
  try {
    var isWindows = /Win/i.test(navigator.platform || navigator.userAgent || "");
    if (isWindows) {
      ["os-win", "sshos-win"].forEach(function (id) {
        var el = document.getElementById(id);
        if (el) el.checked = true;
      });
    }
  } catch (e) {}

  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var targetId = btn.getAttribute("data-copy-target");
      var target = document.getElementById(targetId);
      var codeEl = target ? target.querySelector("code") : null;
      var text = codeEl ? codeEl.textContent : "";
      if (!text) return;
      var done = function () {
        var original = btn.textContent;
        btn.textContent = "Copied!";
        btn.setAttribute("data-copied", "true");
        setTimeout(function () {
          btn.textContent = original;
          btn.removeAttribute("data-copied");
        }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, done);
      } else {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); } catch (e) {}
        document.body.removeChild(ta);
        done();
      }
    });
  });

  // GitHub key verification — public, unauthenticated GitHub API calls
  // made directly from the browser (github.com CORS-allows these).
  var verifyForm = document.getElementById("verify-form");
  var verifyResults = document.getElementById("verify-results");

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[c];
    });
  }

  function formatDate(iso) {
    if (!iso) return "unknown date";
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "unknown date";
    return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
  }

  function fetchKeys(url) {
    return fetch(url, { headers: { "Accept": "application/vnd.github+json" } })
      .then(function (r) {
        if (r.status === 404) return { error: "not_found" };
        if (r.status === 403) return { error: "rate_limited" };
        if (!r.ok) return { error: "http_" + r.status };
        return r.json().then(function (data) { return { data: data }; });
      })
      .catch(function () { return { error: "network" }; });
  }

  function errorMessage(err) {
    switch (err) {
      case "not_found": return "User not found.";
      case "rate_limited": return "GitHub's public API rate limit was hit (60/hour, unauthenticated) — try again later.";
      case "network": return "Network error — couldn't reach the GitHub API.";
      default: return "Something went wrong (" + err + ").";
    }
  }

  function renderSshCard(result) {
    var html = '<div class="verify-card"><h3>SSH Signing Keys';
    if (result.error) {
      html += '<span class="verify-badge danger">error</span></h3><p class="verify-hint">' + errorMessage(result.error) + '</p></div>';
      return html;
    }
    var keys = result.data || [];
    html += '<span class="count-badge">' + keys.length + '</span></h3>';
    if (!keys.length) {
      html += '<p class="verify-hint">No SSH signing keys registered.</p>';
    } else {
      html += '<ul>' + keys.map(function (k) {
        var alg = (k.key || "").split(" ")[0] || "ssh-key";
        return '<li><code>' + escapeHtml(alg) + '</code> — ' + escapeHtml(k.title || "untitled") +
          ' <span class="verify-badge ok">active</span>' +
          '<div class="key-meta">added ' + formatDate(k.created_at) + '</div></li>';
      }).join("") + '</ul>';
    }
    html += '</div>';
    return html;
  }

  function renderGpgCard(result) {
    var html = '<div class="verify-card"><h3>GPG Keys';
    if (result.error) {
      html += '<span class="verify-badge danger">error</span></h3><p class="verify-hint">' + errorMessage(result.error) + '</p></div>';
      return html;
    }
    var keys = result.data || [];
    html += '<span class="count-badge">' + keys.length + '</span></h3>';
    var hasExpired = false;
    if (!keys.length) {
      html += '<p class="verify-hint">No GPG keys registered.</p>';
    } else {
      html += '<ul>' + keys.map(function (k) {
        var expired = k.expires_at && new Date(k.expires_at) < new Date();
        if (expired && !k.revoked) hasExpired = true;
        var badge = k.revoked
          ? '<span class="verify-badge danger">revoked</span>'
          : (expired ? '<span class="verify-badge warn">expired</span>' : '<span class="verify-badge ok">active</span>');
        return '<li><code>' + escapeHtml(k.key_id || "") + '</code> ' + badge +
          '<div class="key-meta">added ' + formatDate(k.created_at) +
          (k.expires_at ? ', expires ' + formatDate(k.expires_at) : ', no expiration') + '</div></li>';
      }).join("") + '</ul>';
      if (hasExpired) {
        html += '<p class="verify-hint spaced">Don\'t delete expired keys — old commits signed with them still need the public key around to verify. Only remove one once you\'re sure nothing relies on it anymore.</p>';
      }
    }
    html += '</div>';
    return html;
  }

  if (verifyForm) {
    verifyForm.addEventListener("submit", function (e) {
      e.preventDefault();
      var input = document.getElementById("verify-username");
      var username = input ? input.value.trim().replace(/^@/, "") : "";
      if (!username) return;
      verifyResults.innerHTML = '<p class="verify-hint">Checking ' + escapeHtml(username) + '…</p>';
      var base = "https://api.github.com/users/" + encodeURIComponent(username) + "/";
      Promise.all([fetchKeys(base + "ssh_signing_keys"), fetchKeys(base + "gpg_keys")]).then(function (res) {
        verifyResults.innerHTML = '<div class="verify-grid">' + renderSshCard(res[0]) + renderGpgCard(res[1]) + '</div>';
      });
    });
  }

  // Live GitHub star count on the header link — best-effort, fails silently
  var starPill = document.getElementById("star-count");
  var starNum = document.getElementById("star-count-num");
  if (starPill && starNum) {
    fetch("https://api.github.com/repos/hbenali/commit-signing-web", { cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        var count = data && typeof data.stargazers_count === "number" ? data.stargazers_count : null;
        if (!count) return;
        starNum.textContent = count >= 1000 ? (count / 1000).toFixed(1) + "k" : String(count);
        starPill.hidden = false;
      })
      .catch(function () {});
  }

  // Scroll-to-top button
  var scrollTopBtn = document.getElementById("scroll-top-btn");
  if (scrollTopBtn) {
    var toggleScrollBtn = function () {
      scrollTopBtn.classList.toggle("visible", window.scrollY > 400);
    };
    window.addEventListener("scroll", toggleScrollBtn, { passive: true });
    toggleScrollBtn();
    scrollTopBtn.addEventListener("click", function () {
      var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      window.scrollTo({ top: 0, behavior: reduceMotion ? "auto" : "smooth" });
    });
  }
})();

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js");
}
