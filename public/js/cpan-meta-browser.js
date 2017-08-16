/* This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
   This is free software, licensed under:
     The Artistic License 2.0 (GPL Compatible)
*/

var search_data = { packages: [], module_perms: [], author_perms: [], authors: [] };
var search_vm = new Vue({
  el: '#search-tab',
  data: search_data,
  methods: {
    search_packages: function() {
      var package_name = $('#package-search-text-input').val();
      var exact_match = $('#package-search-exact-match').is(':checked');
      if (package_name.length === 0 || (!exact_match && package_name.length === 1)) {
        return null;
      }
      var res = $.getJSON('/api/v1/packages/' + encodeURIComponent(package_name), { as_prefix: exact_match ? 0 : 1 })
        .done(function(data) {
          search_data.packages = data;
        })
        .fail(function() {
        });
    },
    search_module_perms: function() {
      var package_name = $('#module-perms-search-text-input').val();
      var exact_match = $('#module-perms-search-exact-match').is(':checked');
      if (package_name.length === 0 || (!exact_match && package_name.length === 1)) {
        return null;
      }
      var res = $.getJSON('/api/v1/perms/by-module/' + encodeURIComponent(package_name), { as_prefix: exact_match ? 0 : 1 })
        .done(function(data) {
          search_data.module_perms = data;
        })
        .fail(function() {
        });
    },
    search_author_perms: function() {
      var author_id = $('#author-perms-search-text-input').val();
      if (author_id.length === 0) {
        return null;
      }
      var res = $.getJSON('/api/v1/perms/by-author/' + encodeURIComponent(author_id))
        .done(function(data) {
          search_data.author_perms = data;
        })
        .fail(function() {
        })
    },
    search_authors: function() {
      var author_id = $('#author-search-text-input').val();
      var exact_match = $('#author-search-exact-match').is(':checked');
      if (author_id.length === 0 || (!exact_match && author_id.length === 1)) {
        return null;
      }
      var res = $.getJSON('/api/v1/authors/' + encodeURIComponent(author_id), { as_prefix: exact_match ? 0 : 1 })
        .done(function(data) {
          search_data.authors = data;
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
