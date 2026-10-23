// Waits for the JS host, then starts the Flutter web app from app/.
(function () {
  'use strict';
  var ready = globalThis.subconsciousExtensionReady || Promise.resolve();
  ready.then(function () {
    var s = document.createElement('script');
    s.src = 'flutter_bootstrap.js';
    s.async = true;
    document.body.appendChild(s);
  });
})();
