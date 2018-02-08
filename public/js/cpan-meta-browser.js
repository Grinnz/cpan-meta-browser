/* This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
   This is free software, licensed under:
     The Artistic License 2.0 (GPL Compatible)
*/

var search_data = {
  search_type: null,
  search_query: '',
  search_match_mode: 'prefix',
  search_author: '',
  package_search_results: null,
  package_data_refreshed: null,
  perms_search_results: null,
  perms_data_refreshed: null,
  author_search_results: null,
  author_data_refreshed: null,
  changing_hash: false,
  changing_search: false
};
var search_vm = new Vue({
  el: '#search-tab',
  data: search_data,
  methods: {
    do_search: function() {
      switch (search_data.search_type) {
        case 'packages':
          return search_vm.search_packages();
        case 'perms':
          return search_vm.search_perms();
        case 'authors':
          return search_vm.search_authors();
        default:
          console.log('Unknown search type ' + search_data.search_type);
      }
    },
    search_packages: function() {
      var query = search_data.search_query;
      var as_prefix = search_data.search_match_mode === 'prefix';
      search_vm.hash_from_search();
      if (query.length === 0 || (as_prefix && query.length === 1)) {
        search_data.package_search_results = null;
        search_data.package_data_refreshed = null;
      } else {
        var packages_url = new URL('/api/v2/packages/' + encodeURIComponent(query), window.location.href);
        packages_url.searchParams.set('as_prefix', as_prefix ? 1 : 0);
        fetch(packages_url).then(function(response) {
          return response.json();
        }).then(function(data) {
          search_data.package_search_results = data.data;
          search_data.package_data_refreshed = data.last_updated;
        }).catch(function(error) {
          console.log('Error retrieving packages', error);
        });
      }
    },
    search_perms: function() {
      var query = search_data.search_query;
      var author = search_data.search_author;
      var as_prefix = search_data.search_match_mode === 'prefix';
      search_vm.hash_from_search();
      if ((query.length === 0 || (as_prefix && query.length === 1)) && author.length === 0) {
        search_data.perms_search_results = null;
        search_data.perms_data_refreshed = null;
      } else {
        var perms_url = new URL('/api/v2/perms', window.location.href);
        perms_url.searchParams.set('author', author);
        perms_url.searchParams.set('module', query);
        perms_url.searchParams.set('as_prefix', as_prefix ? 1 : 0);
        fetch(perms_url).then(function(response) {
          return response.json();
        }).then(function(data) {
          search_data.perms_search_results = data.data;
          search_data.perms_data_refreshed = data.last_updated;
        }).catch(function(error) {
          console.log('Error retrieving perms', error);
        });
      }
    },
    search_authors: function() {
      var query = search_data.search_query;
      var as_prefix = search_data.search_match_mode === 'prefix';
      search_vm.hash_from_search();
      if (query.length === 0 || (as_prefix && query.length === 1)) {
        search_data.author_search_results = null;
        search_data.author_data_refreshed = null;
      } else {
        var authors_url = new URL('/api/v2/authors/' + encodeURIComponent(query), window.location.href);
        authors_url.searchParams.set('as_prefix', as_prefix ? 1 : 0);
        fetch(authors_url).then(function(response) {
          return response.json();
        }).then(function(data) {
          search_data.author_search_results = data.data;
          search_data.author_data_refreshed = data.last_updated;
        }).catch(function(error) {
          console.log('Error retrieving authors', error);
        });
      }
    },
    module_url: function(module) {
      return 'https://metacpan.org/pod/' + encodeURI(module);
    },
    author_url: function(author) {
      return 'https://metacpan.org/author/' + encodeURIComponent(author);
    },
    author_homepage: function(url) {
      var re = new RegExp('^(?:[a-z]+:)?//', 'i');
      if (re.test(url)) {
        return url;
      } else {
        return 'http://' + url;
      }
    },
    cpandir_url: function(path) {
      return 'https://cpan.metacpan.org/authors/id/' + encodeURI(path);
    },
    release_name: function(path) {
      var re = new RegExp('([^/]+)\.(tar\.(?:g?z|bz2)|zip|tgz)$', 'i'); // from CPAN::DistNameInfo
      var matches = re.exec(path);
      if (matches !== null) {
        return matches[1];
      } else {
        return null;
      }
    },
    release_url: function(uploader, path) {
      var name = search_vm.release_name(path);
      if (name !== null) {
        return 'https://metacpan.org/release/' + encodeURIComponent(uploader) + '/' + encodeURIComponent(name);
      } else {
        return 'https://metacpan.org/author/' + encodeURIComponent(uploader) + '/releases';
      }
    },
    permission_string: function(perm) {
      switch (perm.toLowerCase()) {
        case 'm':
          return 'modulelist';
        case 'f':
          return 'first-come';
        case 'a':
          return 'admin';
        case 'c':
          return 'co-maint';
        default:
          return '';
      }
    },
    to_date_string: function(epoch) {
      if (epoch !== null) {
        var date = new Date(epoch * 1000);
        return date.toString();
      } else {
        return '';
      }
    },
    to_utc_string: function(epoch) {
      if (epoch !== null) {
        var date = new Date(epoch * 1000);
        return date.toUTCString();
      } else {
        return '';
      }
    },
    author_cpandir: function(author) {
      return author.substring(0, 1) + '/' + author.substring(0, 2) + '/' + author;
    },
    hash_from_search: function() {
      if (!search_data.changing_search) {
        var separator = search_data.search_match_mode === 'exact' ? '=' : '~';
        var new_hash = search_data.search_author + separator + search_data.search_query;
        if ('#' + new_hash !== window.location.hash) {
          search_data.changing_hash = true;
          window.location.hash = new_hash;
        }
      }
    },
    search_from_hash: function() {
      var hash = window.location.hash;
      if (hash != null && hash.length > 1 && hash.substring(0, 1) === '#') {
        var delim_index = hash.indexOf('=', 1);
        if (delim_index !== -1) {
          search_data.search_match_mode = 'exact';
        } else {
          delim_index = hash.indexOf('~', 1);
          if (delim_index !== -1) {
            search_data.search_match_mode = 'prefix';
          }
        }
        if (delim_index !== -1) {
          search_data.search_author = hash.substring(1, delim_index);
          search_data.search_query = hash.substring(delim_index + 1);
        }
      }
    }
  }
});

window.onload = function() {
  search_data.search_type = document.getElementById('search-type').getAttribute('value');
  search_vm.search_from_hash();
  search_data.changing_search = true;
  search_vm.do_search();
  search_data.changing_search = false;
};

window.addEventListener('hashchange', function() {
  if (search_data.changing_hash) {
    search_data.changing_hash = false;
  } else {
    search_vm.search_from_hash();
    search_data.changing_search = true;
    search_vm.do_search();
    search_data.changing_search = false;
  }
}, false);
