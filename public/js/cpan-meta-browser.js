/* This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
   This is free software, licensed under:
     The Artistic License 2.0 (GPL Compatible)
*/

var search_data = {
  package_search_results: [],
  package_search_query: null,
  package_search_exact_match: false,
  module_perms_search_results: [],
  module_perms_search_query: null,
  module_perms_search_exact_match: false,
  author_perms_search_results: [],
  author_perms_search_query: null,
  author_search_results: [],
  author_search_query: null,
  author_search_exact_match: false
};
var search_vm = new Vue({
  el: '#search-tab',
  data: search_data,
  methods: {
    search_packages: function() {
      var query = search_data.package_search_query;
      var exact_match = search_data.package_search_exact_match;
      if (query.length === 0 || (!exact_match && query.length === 1)) {
        return null;
      }
      var res = $.getJSON('/api/v1/packages/' + encodeURIComponent(query), { as_prefix: exact_match ? 0 : 1 })
        .done(function(data) {
          search_data.package_search_results = data;
        })
        .fail(function() {
        });
    },
    search_module_perms: function() {
      var query = search_data.module_perms_search_query;
      var exact_match = search_data.module_perms_search_exact_match;
      if (query.length === 0 || (!exact_match && query.length === 1)) {
        return null;
      }
      var res = $.getJSON('/api/v1/perms/by-module/' + encodeURIComponent(query), { as_prefix: exact_match ? 0 : 1 })
        .done(function(data) {
          search_data.module_perms_search_results = data;
        })
        .fail(function() {
        });
    },
    search_author_perms: function() {
      var query = search_data.author_perms_search_query;
      if (query.length === 0) {
        return null;
      }
      var res = $.getJSON('/api/v1/perms/by-author/' + encodeURIComponent(query))
        .done(function(data) {
          search_data.author_perms_search_results = data;
        })
        .fail(function() {
        })
    },
    search_authors: function() {
      var query = search_data.author_search_query;
      var exact_match = search_data.author_search_exact_match;
      if (query.length === 0 || (!exact_match && query.length === 1)) {
        return null;
      }
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
    }
  }
});
