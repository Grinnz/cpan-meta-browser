#!/usr/bin/env perl

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

package CPANMetaBrowser::Command::refresh {
use Mojo::Base 'Mojolicious::Command';
use experimental 'signatures';
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Mojo::DOM;
use Mojo::File 'path';
use Mojo::URL;
use Mojo::Util 'decode';
use Syntax::Keyword::Try;
use Text::CSV_XS;

use constant CPAN_MIRROR_METACPAN => 'https://cpan.metacpan.org/';

sub run ($self) {
  try {
    prepare_02packages($self->app);
    prepare_06perms($self->app);
    prepare_00whois($self->app);
    $self->app->log->debug('Refreshed cpan-meta database');
    print "Refreshed cpan-meta database\n";
  } catch {
    $self->app->log->error("Failed to refresh cpan-meta database: $@");
    die "Failed to refresh cpan-meta database: $@";
  }
}

sub cache_file ($app, $filename, $inflate = 0) {
  my $url = Mojo::URL->new(CPAN_MIRROR_METACPAN)->path($filename);
  my $local_path = $app->cache_dir->child($filename);
  $local_path->dirname->make_path;
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
  my $packages_path = cache_file($app, 'modules/02packages.details.txt.gz', 1);
  
  my $fh = path($packages_path)->open('r');
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

my %valid_permission = (m => 1, f => 1, c => 1);
sub prepare_06perms ($app) {
  my $perms_path = cache_file($app, 'modules/06perms.txt.gz', 1);
  
  my $fh = path($perms_path)->open('r');
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
    unless (exists $valid_permission{$best_permission}) {
      $app->log->warn("06perms.txt: Found invalid permission type $best_permission for $userid on module $package");
      next;
    }
    $db->insert('perms', {package => $package, userid => $userid, best_permission => $best_permission});
  }
  $tx->commit;
}

sub prepare_00whois ($app) {
  my $whois_path = cache_file($app, 'authors/00whois.xml');
  
  my $contents = decode 'UTF-8', path($whois_path)->slurp;
  
  my $dom = Mojo::DOM->new->xml(1)->parse($contents);
  
  my $db = $app->sqlite->db;
  my $tx = $db->begin;
  $db->delete('authors');
  
  foreach my $author (@{$dom->find('cpanid')}) {
    next unless $author->at('type')->text eq 'author';
    my %details;
    foreach my $detail (qw(id fullname asciiname email homepage introduced has_cpandir)) {
      my $elem = $author->at($detail) // next;
      $details{$detail} = $elem->text;
    }
    next unless defined $details{id};
    $db->insert('authors', {cpanid => $details{id}, fullname => $details{fullname}, asciiname => $details{asciiname}, email => $details{email},
      homepage => $details{homepage}, introduced => $details{introduced}, has_cpandir => $details{has_cpandir}});
  }
  $tx->commit;
}

} # end CPANMetaBrowser::Command::refresh

use Mojolicious::Lite;
use experimental 'signatures';
use Mojo::JSON::MaybeXS;
use Mojo::JSON qw(true false);
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
my $access_log = app->config->{access_log} // 'log/access.log';

my $old_level = app->log->level;
app->log->level('error'); # hack around AccessLog's dumb warning
plugin 'AccessLog' => {log => $access_log} if $access_log;
app->log->level($old_level);

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

get '/api/v1/authors/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $as_prefix = $c->param('as_prefix');
  my ($where, @params);
  if ($as_prefix) {
    $where = '"cpanid" LIKE ? ESCAPE ?';
    @params = (($author =~ s/[%_]/\\$1/gr) . '%', '\\');
  } else {
    $where = '"cpanid" COLLATE NOCASE = ?';
    @params = ($author);
  }
  my $details = $c->sqlite->db->query('SELECT "cpanid" AS "author", "fullname", "asciiname", "email", "homepage", "introduced", "has_cpandir"
    FROM "authors" WHERE ' . $where . ' ORDER BY "cpanid" COLLATE NOCASE', @params)->hashes;
  $_->{has_cpandir} = $_->{has_cpandir} ? true : false for @$details;
  $c->render(json => $details);
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
      <li role="presentation"><a href="#authors" aria-controls="authors" role="tab" data-toggle="tab">Author Search</a></li>
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
      <div role="tabpanel" class="tab-pane" id="authors">
        <br>
        <form class="form-inline" action="#" id="author-search-form">
          <div class="form-group">
            <label class="sr-only" for="author-search-text-input">Author PAUSE ID</label>
            <input type="text" class="form-control" id="author-search-text-input" placeholder="Author PAUSE ID">
          </div>
          <div class="checkbox">
            <label><input type="checkbox" id="author-search-exact-match"> Exact Match</label>
          </div>
          <button type="submit" class="btn btn-primary">Search</button>
        </form>
        <br>
        <div id="author-search-results">
          <table class="table table-striped table-condensed" id="author-search-results-table">
            <tr id="author-search-results-header"><th>Author</th><th>Name</th><th>Email</th><th>Homepage</th><th>Introduced</th><th>CPAN Directory</th></tr>
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
  </script>
% if (defined $c->config->{google_analytics_tracking_id}) {
  <script>
    (function(i,s,o,g,r,a,m){i['GoogleAnalyticsObject']=r;i[r]=i[r]||function(){
    (i[r].q=i[r].q||[]).push(arguments)},i[r].l=1*new Date();a=s.createElement(o),
    m=s.getElementsByTagName(o)[0];a.async=1;a.src=g;m.parentNode.insertBefore(a,m)
    })(window,document,'script','https://www.google-analytics.com/analytics.js','ga');

    ga('create', '<%= $c->config->{google_analytics_tracking_id} %>', 'auto');
    ga('send', 'pageview');
  </script>
% }
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

-- 2 up
CREATE TABLE IF NOT EXISTS "authors" (
  "cpanid" TEXT NOT NULL PRIMARY KEY,
  "fullname" TEXT NULL,
  "asciiname" TEXT NULL,
  "email" TEXT NULL,
  "homepage" TEXT NULL,
  "introduced" INTEGER NULL,
  "has_cpandir" INTEGER NULL
);

--2 down
DROP TABLE IF EXISTS "authors";
