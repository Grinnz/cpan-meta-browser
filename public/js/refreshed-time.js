/* This software is Copyright (c) 2019 by Dan Book <dbook@cpan.org>.
   This is free software, licensed under:
     The Artistic License 2.0 (GPL Compatible)
*/

window.addEventListener('load', function() {
  var elem = document.getElementById('refreshed-time');
  if (elem !== null) {
    var date = new Date(elem.dataset.epoch * 1000);
    elem.textContent = date.toString();
  }
}, false);
