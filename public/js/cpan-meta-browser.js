/* This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
   This is free software, licensed under:
     The Artistic License 2.0 (GPL Compatible)
*/

$(function() {
  $('.nav-tabs').stickyTabs();
  $('#package-search-form').submit(function(event) {
    event.preventDefault();
    var package_name = $('#package-search-text-input').val();
    var exact_match = $('#package-search-exact-match').is(':checked');
    if (package_name.length === 0 || (!exact_match && package_name.length === 1)) {
      return null;
    }
    $('#package-search-results-header').nextAll('tr').remove();
    var res = $.getJSON('/api/v1/packages/' + encodeURIComponent(package_name), { as_prefix: exact_match ? 0 : 1 })
      .done(function(data) {
        $('#package-search-results-header').nextAll('tr').remove();
        data.forEach(function(row_result) {
          var new_row = $('<tr></tr>');
          ['module','version','owner','uploader','path'].forEach(function(key) {
            var cell = $('<td></td>');
            var value = row_result[key];
            switch (key) {
              case 'module':
                var url = 'https://metacpan.org/pod/' + encodeURI(value);
                cell.append($('<a></a>').attr('href', url).text(value));
                break;
              case 'owner':
              case 'uploader':
                var url = 'https://metacpan.org/author/' + encodeURIComponent(value);
                cell.append($('<a></a>').attr('href', url).text(value));
                break;
              case 'path':
                var url = 'https://cpan.metacpan.org/authors/id/' + encodeURI(value);
                cell.append($('<a></a>').attr('href', url).text(value));
                break;
              default:
                cell.text(value);
            }
            new_row.append(cell);
          });
          $('#package-search-results-table').append(new_row);
        });
      })
      .fail(function() {
      });
  });
  $('#module-perms-search-form').submit(function(event) {
    event.preventDefault();
    var package_name = $('#module-perms-search-text-input').val();
    var exact_match = $('#module-perms-search-exact-match').is(':checked');
    if (package_name.length === 0 || (!exact_match && package_name.length === 1)) {
      return null;
    }
    $('#module-perms-search-results-header').nextAll('tr').remove();
    var res = $.getJSON('/api/v1/perms/by-module/' + encodeURIComponent(package_name), { as_prefix: exact_match ? 0 : 1 })
      .done(function(data) {
        $('#module-perms-search-results-header').nextAll('tr').remove();
        data.forEach(function(row_result) {
          var new_row = $('<tr></tr>');
          ['module','author','best_permission','owner'].forEach(function(key) {
            var cell = $('<td></td>');
            var value = row_result[key];
            switch (key) {
              case 'module':
                var url = 'https://metacpan.org/pod/' + encodeURI(value);
                cell.append($('<a></a>').attr('href', url).text(value));
                break;
              case 'author':
              case 'owner':
                var url = 'https://metacpan.org/author/' + encodeURIComponent(value);
                cell.append($('<a></a>').attr('href', url).text(value));
                break;
              case 'best_permission':
                var perm = '';
                switch (row_result[key].toLowerCase()) {
                  case 'm':
                    perm = 'modulelist';
                    break;
                  case 'f':
                    perm = 'first-come';
                    break;
                  case 'c':
                    perm = 'co-maint';
                    break;
                }
                cell.text(perm);
                break;
              default:
                cell.text(value);
            }
            new_row.append(cell);
          });
          $('#module-perms-search-results-table').append(new_row);
        });
      })
      .fail(function() {
      });
  });
  $('#author-perms-search-form').submit(function(event) {
    event.preventDefault();
    var author_id = $('#author-perms-search-text-input').val();
    if (author_id.length === 0) {
      return null;
    }
    $('#author-perms-search-results-header').nextAll('tr').remove();
    var res = $.getJSON('/api/v1/perms/by-author/' + encodeURIComponent(author_id))
      .done(function(data) {
        $('#author-perms-search-results-header').nextAll('tr').remove();
        data.forEach(function(row_result) {
          var new_row = $('<tr></tr>');
          ['module','author','best_permission','owner'].forEach(function(key) {
            var cell = $('<td></td>');
            var value = row_result[key];
            switch (key) {
              case 'module':
                var url = 'https://metacpan.org/pod/' + encodeURI(value);
                cell.append($('<a></a>').attr('href', url).text(value));
                break;
              case 'author':
              case 'owner':
                var url = 'https://metacpan.org/author/' + encodeURIComponent(value);
                cell.append($('<a></a>').attr('href', url).text(value));
                break;
              case 'best_permission':
                var perm = '';
                switch (row_result[key].toLowerCase()) {
                  case 'm':
                    perm = 'modulelist';
                    break;
                  case 'f':
                    perm = 'first-come';
                    break;
                  case 'c':
                    perm = 'co-maint';
                    break;
                }
                cell.text(perm);
                break;
              default:
                cell.text(value);
            }
            new_row.append(cell);
          });
          $('#author-perms-search-results-table').append(new_row);
        });
      })
      .fail(function() {
      });
  });
  $('#author-search-form').submit(function(event) {
    event.preventDefault();
    var author_id = $('#author-search-text-input').val();
    var exact_match = $('#author-search-exact-match').is(':checked');
    if (author_id.length === 0 || (!exact_match && author_id.length === 1)) {
      return null;
    }
    $('#author-search-results-header').nextAll('tr').remove();
    var res = $.getJSON('/api/v1/authors/' + encodeURIComponent(author_id), { as_prefix: exact_match ? 0 : 1 })
      .done(function(data) {
        $('#author-search-results-header').nextAll('tr').remove();
        data.forEach(function(row_result) {
          var new_row = $('<tr></tr>');
          ['author','fullname','email','homepage','introduced','has_cpandir'].forEach(function(key) {
            var cell = $('<td></td>');
            var value = row_result[key];
            switch (key) {
              case 'author':
                var url = 'https://metacpan.org/author/' + encodeURIComponent(value);
                cell.append($('<a></a>').attr('href', url).text(value));
                break;
              case 'fullname':
                cell.text(value);
                var asciiname = row_result.asciiname;
                if (asciiname != null) {
                  cell.attr('title', asciiname);
                }
                break;
              case 'email':
                if (value != null && value === 'CENSORED') {
                  cell.text(value);
                } else {
                  var url = 'mailto:' + value;
                  cell.append($('<a></a>').attr('href', url).text(value));
                }
                break;
              case 'homepage':
                cell.append($('<a></a>').attr('href', value).text(value));
                break;
              case 'introduced':
                if (value != null) {
                  var introduced_date = new Date(value * 1000);
                  cell.text(introduced_date.toUTCString());
                }
                break;
              case 'has_cpandir':
                if (value) {
                  var cpanid = row_result.author;
                  var first_dir = cpanid.substring(0, 1);
                  var second_dir = cpanid.substring(0, 2);
                  var cpandir = '/authors/id/' + first_dir + '/' + second_dir + '/' + cpanid;
                  var url = 'https://cpan.metacpan.org' + encodeURI(cpandir);
                  cell.append($('<a></a>').attr('href', url).text(cpandir));
                }
                break;
              default:
                cell.text(value);
            }
            new_row.append(cell);
          });
          $('#author-search-results-table').append(new_row);
        });
      })
      .fail(function() {
      });
  });
});
