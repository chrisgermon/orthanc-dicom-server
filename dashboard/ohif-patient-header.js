/* Crowd Image Management - Show patient name in OHIF header */
(function() {
  var lastUid = null;
  var el = null;

  function getOrCreateEl() {
    if (el && document.contains(el)) return el;

    el = document.getElementById('ci-patient-info');
    if (el) return el;

    var brand = document.querySelector('.header-brand');
    var anchor = brand || document.querySelector('[class*="Header"] a') || document.querySelector('header a');
    if (!anchor) return null;

    el = document.createElement('span');
    el.id = 'ci-patient-info';
    el.style.cssText = 'color:rgba(255,255,255,0.8);font-size:12px;font-weight:400;margin-left:12px;display:none;align-items:center;gap:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:400px;flex-shrink:1;min-width:0;';
    anchor.parentNode.insertBefore(el, anchor.nextSibling);
    return el;
  }

  function checkStudy() {
    var params = new URLSearchParams(window.location.search);
    var uid = params.get('StudyInstanceUIDs');

    if (!uid) {
      if (el) el.style.display = 'none';
      lastUid = null;
      return;
    }
    if (uid === lastUid) return;
    lastUid = uid;

    var infoEl = getOrCreateEl();
    if (!infoEl) return;

    fetch('/dicom-web/studies?StudyInstanceUID=' + encodeURIComponent(uid) + '&includefield=00100010,00100020,00080020,00081030', {
      headers: { 'Accept': 'application/dicom+json' }
    })
    .then(function(r) { return r.json(); })
    .then(function(studies) {
      if (!studies || !studies.length) {
        infoEl.style.display = 'none';
        return;
      }

      var s = studies[0];
      var patientName = '';
      var patientId = '';
      var studyDate = '';
      var studyDesc = '';

      if (s['00100010'] && s['00100010'].Value) {
        var pn = s['00100010'].Value[0];
        patientName = pn.Alphabetic || pn.toString() || '';
        patientName = patientName.replace(/\^/g, ' ').trim();
      }
      if (s['00100020'] && s['00100020'].Value) {
        patientId = s['00100020'].Value[0] || '';
      }
      if (s['00080020'] && s['00080020'].Value) {
        var d = s['00080020'].Value[0] || '';
        if (d.length === 8) studyDate = d.slice(0,4) + '-' + d.slice(4,6) + '-' + d.slice(6,8);
      }
      if (s['00081030'] && s['00081030'].Value) {
        studyDesc = s['00081030'].Value[0] || '';
      }

      var sep = ' <span style="opacity:0.3">\u00b7</span> ';
      var parts = [];
      if (patientName) parts.push('<b>' + escHtml(patientName) + '</b>');
      if (patientId) parts.push(escHtml(patientId));
      if (studyDate) parts.push(escHtml(studyDate));
      if (studyDesc) parts.push(escHtml(studyDesc));

      if (parts.length) {
        infoEl.innerHTML = parts.join(sep);
        infoEl.style.display = 'inline';
      }
    })
    .catch(function() {
      infoEl.style.display = 'none';
    });
  }

  function escHtml(s) {
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  setInterval(checkStudy, 1000);

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() { setTimeout(checkStudy, 2000); });
  } else {
    setTimeout(checkStudy, 2000);
  }
})();

/* Redirect OHIF back/logo link to management dashboard instead of OHIF worklist */
(function() {
  function fixBackLink() {
    // OHIF header links: logo link, any <a> pointing to "/" in the header
    var links = document.querySelectorAll('header a, [class*="Header"] a, .header-brand');
    for (var i = 0; i < links.length; i++) {
      var a = links[i].closest('a') || links[i];
      if (a.tagName === 'A' && (a.getAttribute('href') === '/' || a.getAttribute('href') === '')) {
        a.setAttribute('href', '/manage/');
      }
    }
  }
  setInterval(fixBackLink, 1500);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() { setTimeout(fixBackLink, 2000); });
  } else {
    setTimeout(fixBackLink, 2000);
  }
})();

/* "Not for Diagnostic Use" overlay on each viewport */
(function() {
  var OVERLAY_CLASS = 'ci-diag-overlay';
  var style = document.createElement('style');
  style.textContent =
    '.' + OVERLAY_CLASS + '{' +
      'position:absolute;bottom:8px;right:8px;' +
      'background:rgba(0,0,0,0.55);' +
      'color:rgba(255,255,255,0.75);' +
      'font-size:11px;font-weight:500;' +
      'padding:4px 10px;border-radius:4px;' +
      'pointer-events:none;z-index:50;' +
      'letter-spacing:0.3px;' +
      'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;' +
    '}';
  document.head.appendChild(style);

  function addOverlays() {
    // OHIF renders viewports inside elements with data-cy="viewport-container" or class containing "viewport"
    var containers = document.querySelectorAll(
      '[data-cy="viewport-container"], [class*="viewport-container"], [class*="ViewportGrid"] > div > div'
    );
    // Fallback: look for cornerstone canvas elements
    if (containers.length === 0) {
      containers = document.querySelectorAll('canvas[class*="cornerstone"]');
      // Use parent of canvas
      var parents = [];
      for (var i = 0; i < containers.length; i++) {
        var p = containers[i].parentElement;
        if (p && parents.indexOf(p) === -1) parents.push(p);
      }
      if (parents.length > 0) containers = parents;
    }

    for (var i = 0; i < containers.length; i++) {
      var c = containers[i];
      // Skip if already has overlay or has no visible canvas/content
      if (c.querySelector('.' + OVERLAY_CLASS)) continue;
      // Only add to elements that contain a canvas (actual viewport rendering)
      if (!c.querySelector('canvas')) continue;
      // Ensure positioned for absolute child
      var pos = window.getComputedStyle(c).position;
      if (pos === 'static') c.style.position = 'relative';

      var overlay = document.createElement('div');
      overlay.className = OVERLAY_CLASS;
      overlay.textContent = 'Not for Diagnostic Use';
      c.appendChild(overlay);
    }
  }

  setInterval(addOverlays, 2000);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() { setTimeout(addOverlays, 3000); });
  } else {
    setTimeout(addOverlays, 3000);
  }
})();
