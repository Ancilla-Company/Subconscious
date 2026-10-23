// Classic-script loader for the extension host (see tools/host_tools.js).
// Pages must await `subconsciousExtensionReady` before starting Flutter (boot.js does).
(function () {
  'use strict';
  globalThis.subconsciousExtensionReady = import('./tools/host_tools.js')
    .then(function (m) {
      globalThis.subconsciousExtension = m.createHost();
      return globalThis.subconsciousExtension;
    })
    .catch(function (e) {
      // Keep the app bootable (without browser tools) if the host fails.
      console.error('Subconscious extension host failed to start', e);
      return null;
    });
})();
