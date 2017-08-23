/* This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
   This is free software, licensed under:
     The Artistic License 2.0 (GPL Compatible)
*/

var search_data = {
  search_type: null,
  search_query: '',
  search_exact_match: false,
  package_search_results: [],
  module_perms_search_results: [],
  author_perms_search_results: [],
  author_search_results: [],
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
        case 'module_perms':
          return search_vm.search_module_perms();
        case 'author_perms':
          return search_vm.search_author_perms();
        case 'authors':
          return search_vm.search_authors();
        default:
          console.log('Unknown search type ' + search_data.search_type);
      }
    },
    search_packages: function() {
      var query = search_data.search_query;
      var exact_match = search_data.search_exact_match;
      if (query.length === 0 || (!exact_match && query.length === 1)) {
        return null;
      }
      search_vm.hash_from_search();
      var res = $.getJSON('/api/v1/packages/' + encodeURIComponent(query), { as_prefix: exact_match ? 0 : 1 })
        .done(function(data) {
          search_data.package_search_results = data;
        })
        .fail(function() {
        });
    },
    search_module_perms: function() {
      var query = search_data.search_query;
      var exact_match = search_data.search_exact_match;
      if (query.length === 0 || (!exact_match && query.length === 1)) {
        return null;
      }
      search_vm.hash_from_search();
      var res = $.getJSON('/api/v1/perms/by-module/' + encodeURIComponent(query), { as_prefix: exact_match ? 0 : 1 })
        .done(function(data) {
          search_data.module_perms_search_results = data;
        })
        .fail(function() {
        });
    },
    search_author_perms: function() {
      var query = search_data.search_query;
      if (query.length === 0) {
        return null;
      }
      search_vm.hash_from_search();
      var res = $.getJSON('/api/v1/perms/by-author/' + encodeURIComponent(query))
        .done(function(data) {
          search_data.author_perms_search_results = data;
        })
        .fail(function() {
        })
    },
    search_authors: function() {
      var query = search_data.search_query;
      var exact_match = search_data.search_exact_match;
      if (query.length === 0 || (!exact_match && query.length === 1)) {
        return null;
      }
      search_vm.hash_from_search();
      var res = $.getJSON('/api/v1/authors/' + encodeURIComponent(query), { as_prefix: exact_match ? 0 : 1 })
        .done(function(data) {
          search_data.author_search_results = data;
        })
        .fail(function() {
        })
    },
    module_url: function(module) {
      return 'https://metacpan.org/pod/' + encodeURI(module);
    },
    author_url: function(author) {
      return 'https://metacpan.org/author/' + encodeURIComponent(author);
    },
    cpandir_url: function(path) {
      return 'https://cpan.metacpan.org/authors/id/' + encodeURI(path);
    },
    permission_string: function(perm) {
      switch (perm.toLowerCase()) {
        case 'm':
          return 'modulelist';
        case 'f':
          return 'first-come';
        case 'c':
          return 'co-maint';
        default:
          return '';
      }
    },
    to_date_string: function(epoch) {
      if (epoch != null) {
        var date = new Date(epoch * 1000);
        return date.toUTCString();
      }
      return '';
    },
    author_cpandir: function(author) {
      return author.substring(0, 1) + '/' + author.substring(0, 2) + '/' + author;
    },
    hash_from_search: function() {
      if (!search_data.changing_search) {
        var new_hash = (search_data.search_exact_match ? '=' : '~') + search_data.search_query;
        if ('#' + new_hash !== window.location.hash) {
          search_data.changing_hash = true;
          window.location.hash = new_hash;
          search_data.changing_hash = false;
        }
      }
    },
    search_from_hash: function() {
      var hash = window.location.hash;
      if (hash != null && hash.length > 2 && hash.substring(0, 1) === '#') {
        switch (hash.substring(1, 2)) {
          case '=':
            search_data.search_exact_match = true;
            break;
          case '~':
            search_data.search_exact_match = false;
            break;
          default:
            return null;
        }
        search_data.search_query = hash.substring(2);
      }
    }
  }
});

$(function() {
  search_data.search_type = $('#search-type').val();
  search_vm.search_from_hash();
  search_data.changing_search = true;
  search_vm.do_search();
  search_data.changing_search = false;
});

window.addEventListener('hashchange', function() {
  if (!search_data.changing_hash) {
    search_vm.search_from_hash();
    search_data.changing_search = true;
    search_vm.do_search();
    search_data.changing_search = false;
  }
}, false);
