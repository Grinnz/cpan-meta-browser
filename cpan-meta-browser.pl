#!/usr/bin/env perl

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

package CPANMetaBrowser::Command::refresh {
use Mojo::Base 'Mojolicious::Command';
use experimental 'signatures';
use File::Open 'fopen';
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Mojo::URL;
use Syntax::Keyword::Try;
use Text::CSV_XS;

use constant CPAN_MIRROR_METACPAN => 'https://cpan.metacpan.org/';

sub run ($self) {
  try {
    prepare_02packages($self->app);
    prepare_06perms($self->app);
    $self->app->log->debug('Refreshed cpan-meta database');
    print "Refreshed cpan-meta database\n";
  } catch {
    $self->app->log->error("Failed to refresh cpan-meta database: $@");
    die "Failed to refresh cpan-meta database: $@";
  }
}

sub cache_file ($app, $filename, $inflate) {
  my $url = Mojo::URL->new(CPAN_MIRROR_METACPAN)->path("modules/$filename");
  my $local_path = $app->cache_dir->child($filename);
  my $res = $app->httptiny->mirror($url, $local_path);
  die "Failed to cache file from $url to $local_path: $res->{content}\n" if $res->{status} == 599;
  die "Failed to cache file from $url to $local_path: $res->{status} $res->{reason}\n" unless $res->{success};
  $app->log->debug("Cached file from $url to $local_path: $res->{status} $res->{reason}");
  if ($inflate) {
    my $unzipped_path = $local_path =~ s/\.gz\z//r;
    return $local_path if $local_path eq $unzipped_path;
    my $rc = gunzip("$local_path" => "$unzipped_path") or die "Failed to gunzip $local_path: $GunzipError\n";
    $app->log->debug("Inflated $local_path to $unzipped_path");
    return $unzipped_path;
  } else {
    return $local_path;
  }
}

sub prepare_02packages ($app) {
  my $packages_path = cache_file($app, '02packages.details.txt.gz', 1);
  
  my $fh = fopen $packages_path, 'r';
  while (defined(my $line = readline $fh)) {
    last if $line =~ m/^\s*$/;
  }
  
  my $db = $app->sqlite->db;
  my $tx = $db->begin;
  $db->delete('packages');
  
  while (defined(my $line = readline $fh)) {
    chomp $line;
    my ($package, $version, $path) = split /\s+/, $line, 3;
    next unless length $version;
    $version = undef if $version eq 'undef';
    $db->insert('packages', {package => $package, version => $version, path => ($path // '')});
  }
  $tx->commit;
}

sub prepare_06perms ($app) {
  my $perms_path = cache_file($app, '06perms.txt.gz', 1);
  
  my $fh = fopen $perms_path, 'r';
  while (defined(my $line = readline $fh)) {
    last if $line =~ m/^\s*$/;
  }
  
  my $db = $app->sqlite->db;
  my $tx = $db->begin;
  $db->delete('perms');
  
  my $csv = Text::CSV_XS->new({binary => 1});
  $csv->bind_columns(\my $package, \my $userid, \my $best_permission);
  while ($csv->getline($fh)) {
    next unless length $package and length $userid and length $best_permission;
    unless ($best_permission eq 'm' or $best_permission eq 'f' or $best_permission eq 'c') {
      $app->log->warn("06perms.txt: Found invalid permission type $best_permission for $userid on module $package");
      next;
    }
    $db->insert('perms', {package => $package, userid => $userid, best_permission => $best_permission});
  }
  $tx->commit;
}

} # end CPANMetaBrowser::Command::refresh

use Mojolicious::Lite;
use experimental 'signatures';
use Mojo::JSON::MaybeXS;
use Mojo::SQLite;
use Mojo::URL;
use Mojo::Util 'trim';
use HTTP::Tiny;

my $cache_dir = app->home->child('cache')->make_path;

my $sqlite_path = app->home->child('cpan-meta.sqlite');
my $sqlite = Mojo::SQLite->new->from_filename($sqlite_path);
$sqlite->migrations->from_data(__PACKAGE__, 'cpan-meta')->migrate;

push @{app->commands->namespaces}, 'CPANMetaBrowser::Command';

my $httptiny;
helper 'httptiny' => sub { $httptiny //= HTTP::Tiny->new };
helper 'cache_dir' => sub { $cache_dir };
helper 'sqlite' => sub { $sqlite };

plugin 'Config' => {file => 'cpan-meta-browser.conf', default => {}};

get '/' => 'index';

get '/api/v1/packages/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my ($where, @params);
  if ($as_prefix) {
    $where = '"p"."package" LIKE ? ESCAPE ?';
    @params = (($module =~ s/[%_]/\\$1/gr) . '%', '\\');
  } else {
    $where = '"p"."package" COLLATE NOCASE = ?';
    @params = ($module);
  }
  my $details = $c->sqlite->db->query('SELECT "p"."package" AS "module", "p"."version", "p"."path",
    (SELECT "userid" FROM "perms" WHERE "package"="p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
    FROM "packages" AS "p" WHERE ' . $where . ' ORDER BY "p"."package" COLLATE NOCASE', 'f', @params)->hashes;
  ($_->{uploader}) = $_->{path} =~ m{^[^/]+/[^/]+/([a-z]+)}i for @$details;
  $c->render(json => $details);
};

get '/api/v1/perms/by-module/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my ($where, @params);
  if ($as_prefix) {
    $where = '"p"."package" LIKE ? ESCAPE ?';
    @params = (($module =~ s/[%_]/\\$1/gr) . '%', '\\');
  } else {
    $where = '"p"."package" COLLATE NOCASE = ?';
    @params = ($module);
  }
  my $perms = $c->sqlite->db->query('SELECT "p"."package" AS "module", "p"."userid" AS "author", "p"."best_permission",
    (SELECT "userid" FROM "perms" WHERE "package"="p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
    FROM "perms" AS "p" WHERE ' . $where . ' ORDER BY "p"."package" COLLATE NOCASE, "p"."userid" COLLATE NOCASE', 'f', @params)->hashes;
  $c->render(json => $perms);
};

get '/api/v1/perms/by-author/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $perms = $c->sqlite->db->query('SELECT "p"."userid" AS "author", "p"."package" AS "module", "p"."best_permission",
    (SELECT "userid" FROM "perms" WHERE "package"="p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
    FROM "perms" AS "p" WHERE "p"."userid" COLLATE NOCASE = ? ORDER BY "p"."package" COLLATE NOCASE', 'f', $author)->hashes;
  $c->render(json => $perms);
};

app->start;

__DATA__
@@ index.html.ep
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CPAN Meta Browser</title>
  <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap.min.css" integrity="sha384-BVYiiSIFeK1dGmJRAkycuHAHRg32OmUcww7on3RYdg4Va+PmSTsz/K68vbdEjh4u" crossorigin="anonymous">
</head>
<body>
  <div class="container">
    <p class="text-right"><a href="https://github.com/Grinnz/cpan-meta-browser">Source on GitHub</a></p>
    <div class="page-header"><h1>CPAN Meta Browser</h1></div>
    <ul class="nav nav-tabs nav-justified" role="tablist">
      <li role="presentation" class="active"><a href="#packages" aria-controls="packages" role="tab" data-toggle="tab">Module Index Search</a></li>
      <li role="presentation"><a href="#module-perms" aria-controls="module-perms" role="tab" data-toggle="tab">Module Permissions Search</a></li>
      <li role="presentation"><a href="#author-perms" aria-controls="author-perms" role="tab" data-toggle="tab">Author Permissions Search</a></li>
    </ul>
    <div class="tab-content">
      <div role="tabpanel" class="tab-pane active" id="packages">
        <br>
        <form class="form-inline" action="#" id="package-search-form">
          <div class="form-group">
            <label class="sr-only" for="package-search-text-input">Module Name</label>
            <input type="text" class="form-control" id="package-search-text-input" placeholder="Module Name">
          </div>
          <div class="checkbox">
            <label><input type="checkbox" id="package-search-exact-match"> Exact Match</label>
          </div>
          <button type="submit" class="btn btn-primary">Search</button>
        </form>
        <br>
        <div id="package-search-results">
          <table class="table table-striped table-condensed" id="package-search-results-table">
            <tr id="package-search-results-header"><th>Module</th><th>Version</th><th>Owner</th><th>Uploader</th><th>Path</th></tr>
          </table>
        </div>
      </div>
      <div role="tabpanel" class="tab-pane" id="module-perms">
        <br>
        <form class="form-inline" action="#" id="module-perms-search-form">
          <div class="form-group">
            <label class="sr-only" for="module-perms-search-text-input">Module Name</label>
            <input type="text" class="form-control" id="module-perms-search-text-input" placeholder="Module Name">
          </div>
          <div class="checkbox">
            <label><input type="checkbox" id="module-perms-search-exact-match"> Exact Match</label>
          </div>
          <button type="submit" class="btn btn-primary">Search</button>
        </form>
        <br>
        <div id="module-perms-search-results">
          <table class="table table-striped table-condensed" id="module-perms-search-results-table">
            <tr id="module-perms-search-results-header"><th>Module</th><th>Author</th><th>Permission</th><th>Owner</th></tr>
          </table>
        </div>
      </div>
      <div role="tabpanel" class="tab-pane" id="author-perms">
        <br>
        <form class="form-inline" action="#" id="author-perms-search-form">
          <div class="form-group">
            <label class="sr-only" for="author-perms-search-text-input">Author PAUSE ID</label>
            <input type="text" class="form-control" id="author-perms-search-text-input" placeholder="Author PAUSE ID">
          </div>
          <button type="submit" class="btn btn-primary">Search</button>
        </form>
        <br>
        <div id="author-perms-search-results">
          <table class="table table-striped table-condensed" id="author-perms-search-results-table">
            <tr id="author-perms-search-results-header"><th>Module</th><th>Author</th><th>Permission</th><th>Owner</th></tr>
          </table>
        </div>
      </div>
    </div>
  </div>

  <script src="https://code.jquery.com/jquery-3.2.1.min.js" integrity="sha256-hwg4gsxgFZhOsEEamdOYGBf13FyQuiTwlAQgxVSNgt4=" crossorigin="anonymous"></script>
  <script src="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/js/bootstrap.min.js" integrity="sha384-Tc5IQib027qvyjSMfHjOMaLkfuWVxZxUPnCJA7l2mCWNIpG9mGCD8wGNIcPD7Txa" crossorigin="anonymous"></script>
  <script type="text/javascript">
    $(function() {
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
                    url = 'https://metacpan.org/pod/' + encodeURI(value);
                    cell.append($('<a></a>').attr('href', url).text(value));
                    break;
                  case 'owner':
                  case 'uploader':
                    url = 'https://metacpan.org/author/' + encodeURIComponent(value);
                    cell.append($('<a></a>').attr('href', url).text(value));
                    break;
                  case 'path':
                    url = 'https://cpan.metacpan.org/authors/id/' + encodeURI(value);
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
                    url = 'https://metacpan.org/pod/' + encodeURI(value);
                    cell.append($('<a></a>').attr('href', url).text(value));
                    break;
                  case 'author':
                  case 'owner':
                    url = 'https://metacpan.org/author/' + encodeURIComponent(value);
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
                    url = 'https://metacpan.org/pod/' + encodeURI(value);
                    cell.append($('<a></a>').attr('href', url).text(value));
                    break;
                  case 'author':
                  case 'owner':
                    url = 'https://metacpan.org/author/' + encodeURIComponent(value);
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
    });
  </script>
</body>
</html>

@@ cpan-meta

-- 1 up
CREATE TABLE IF NOT EXISTS "packages" (
  "package" TEXT NOT NULL PRIMARY KEY,
  "version" TEXT NULL,
  "path" TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS "perms" (
  "package" TEXT NOT NULL,
  "userid" TEXT NOT NULL,
  "best_permission" TEXT NOT NULL CHECK ("best_permission" IN ('m','f','c')),
  PRIMARY KEY ("package","userid")
);
CREATE INDEX IF NOT EXISTS "perms_userid_best_permission_idx" ON "perms" ("userid","best_permission");
CREATE INDEX IF NOT EXISTS "perms_package_best_permission_idx" ON "perms" ("package","best_permission");

-- 1 down
DROP TABLE IF EXISTS "packages";
DROP TABLE IF EXISTS "perms";
