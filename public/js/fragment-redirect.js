/* This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
   This is free software, licensed under:
     The Artistic License 2.0 (GPL Compatible)
*/

function redirect_from_hash(search_type) {
  var hash = window.location.hash;
  if (hash != null && hash.length > 1 && hash.substring(0, 1) === '#') {
    if (hash.indexOf('%', 1) !== -1) {
      hash = decodeURI(hash);
    }
    var match_mode = 'prefix';
    var delim_index = hash.indexOf('=', 1);
    if (delim_index !== -1) {
      match_mode = 'exact';
    } else {
      delim_index = hash.indexOf('~', 1);
      if (delim_index !== -1) {
        match_mode = 'prefix';
      } else {
        delim_index = hash.indexOf('*', 1);
        if (delim_index !== -1) {
          match_mode = 'infix';
        }
      }
    }
    var module = '';
    var author = '';
    var other_authors = false;
    if (delim_index !== -1) {
      if (delim_index > 0 && hash.substring(delim_index - 1, delim_index) === '+') {
        author = hash.substring(1, delim_index - 1);
        other_authors = true;
      } else {
        author = hash.substring(1, delim_index);
        other_authors = false;
      }
      if (search_type === 'authors') {
        author = hash.substring(delim_index + 1);
      } else {
        module = hash.substring(delim_index + 1);
      }
    }
    if (author !== '' || module !== '') {
      var redir_url = new URL('/' + search_type, window.location.href);
      redir_url.searchParams.set('module', module);
      redir_url.searchParams.set('author', author);
      redir_url.searchParams.set('match_mode', match_mode);
      if (other_authors) { redir_url.searchParams.set('other_authors', 1); }
      window.location.href = redir_url;
    }
  }
}

window.onload = function() {
  var search_type = document.getElementById('search-type').getAttribute('value');
  redirect_from_hash(search_type);
};
