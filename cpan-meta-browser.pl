#!/usr/bin/env perl

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::JSON::MaybeXS;
use Mojolicious::Lite;
use experimental 'signatures';
use Mojo::URL;
use Mojo::Util 'trim';
use HTTP::Tiny;

use lib::relative 'lib';

push @{app->commands->namespaces}, 'CPANMetaBrowser::Command';
push @{app->plugins->namespaces}, 'CPANMetaBrowser::Plugin';

plugin 'Config' => {file => 'cpan-meta-browser.conf', default => {}};

my $httptiny;
helper 'httptiny' => sub { $httptiny //= HTTP::Tiny->new };

my $cache_dir = app->home->child('cache')->make_path;
helper 'cache_dir' => sub { $cache_dir };

my $backend = $ENV{CPAN_META_BROWSER_BACKEND} // app->config->{backend} // 'sqlite';
if ($backend eq 'sqlite') {
  plugin 'Backend::SQLite';
} elsif ($backend eq 'pg') {
  plugin 'Backend::Pg';
} elsif ($backend eq 'redis') {
  plugin 'Backend::Redis';
} else {
  die "Unknown backend '$backend' (should be 'sqlite' or 'pg')\n";
}

helper backend => sub { $backend };

helper _keys_equal => sub ($c, $first, $second, $keys) {
  return 0 unless defined $first and defined $second;
  foreach my $key (@$keys) {
    next if !defined $first->{$key} and !defined $second->{$key};
    return 0 unless defined $first->{$key} and defined $second->{$key} and $first->{$key} eq $second->{$key};
  }
  return 1;
};

helper _sql_pattern_escape => sub ($c, $value) { $value =~ s/([%_\\])/\\$1/gr };

my $access_log = app->config->{access_log} // 'log/access.log';
my $old_level = app->log->level;
app->log->level('error'); # hack around AccessLog's dumb warning
plugin 'AccessLog' => {log => $access_log} if $access_log;
app->log->level($old_level);

get '/' => sub ($c) { $c->redirect_to('packages') } => 'index';
get '/packages';
get '/perms';
get '/module-perms' => sub ($c) { $c->res->code(301); $c->redirect_to('perms') };
get '/author-perms' => sub ($c) { $c->res->code(301); $c->redirect_to('perms') };
get '/authors';

get '/api/v1/packages/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my $packages = $c->get_packages($module, $as_prefix);
  $c->render(json => $packages);
};

get '/api/v1/perms/by-module/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my $perms = $c->get_perms('', $module, $as_prefix);
  $c->render(json => $perms);
};

get '/api/v1/perms/by-author/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $perms = $c->get_perms($author);
  $c->render(json => $perms);
};

get '/api/v1/authors/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $as_prefix = $c->param('as_prefix');
  my $authors = $c->get_authors($author, $as_prefix);
  $c->render(json => $authors);
};

get '/api/v2/packages/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my $as_infix = $c->param('as_infix');
  my $packages = $c->get_packages($module, $as_prefix, $as_infix);
  my $last_updated = $c->get_refreshed('packages');
  $c->render(json => {data => $packages, last_updated => $last_updated});
};

get '/api/v2/perms' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my $as_infix = $c->params('as_infix');
  my $other_authors = $c->param('other_authors');
  my $perms = $c->get_perms($author, $module, $as_prefix, $as_infix, $other_authors);
  my $last_updated = $c->get_refreshed('perms');
  $c->render(json => {data => $perms, last_updated => $last_updated});
};

get '/api/v2/authors/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $as_prefix = $c->param('as_prefix');
  my $as_infix = $c->param('as_infix');
  my $authors = $c->get_authors($author, $as_prefix, $as_infix);
  my $last_updated = $c->get_refreshed('authors');
  $c->render(json => {data => $authors, last_updated => $last_updated});
};

app->start;

