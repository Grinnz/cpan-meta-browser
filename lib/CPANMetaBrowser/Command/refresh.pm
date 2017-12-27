package CPANMetaBrowser::Command::refresh;

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
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
  
  my $backend = $app->backend;
  my $db = _backend_db($app);
  
  my %packages = map { ($_ => 1) } @{existing_packages($backend, $db)};
  
  while (defined(my $line = readline $fh)) {
    chomp $line;
    my ($package, $version, $path) = split /\s+/, $line, 3;
    next unless length $version;
    my %package_data = (package => $package, path => ($path // ''));
    $package_data{version} = $version if defined $version and $version ne 'undef';
    update_package($backend, $db, \%package_data);
    delete $packages{$package};
  }
  
  delete_package($backend, $db, $_) for keys %packages;
}

sub existing_packages ($backend, $db) {
  if ($backend eq 'sqlite') {
    return $db->select('packages', ['package'])->arrays->map(sub { $_->[0] });
  } elsif ($backend eq 'pg') {
    return $db->select('packages', ['package'])->arrays->map(sub { $_->[0] });
  }
}

sub update_package ($backend, $db, $data) {
  if ($backend eq 'sqlite') {
    my $current = $db->select('packages', '*', {package => $data->{package}})->hashes->first;
    return 1 if _keys_equal($data, $current, [qw(version path)]);
    my $query = 'INSERT OR REPLACE INTO "packages" ("package","version","path") VALUES (?,?,?)';
    return $db->query($query, @$data{'package','version','path'});
  } elsif ($backend eq 'pg') {
    my $current = $db->select('packages', '*', {package => $data->{package}})->hashes->first;
    return 1 if _keys_equal($data, $current, [qw(version path)]);
    my $query = 'INSERT INTO "packages" ("package","version","path") VALUES (?,?,?)
      ON CONFLICT ("package") DO UPDATE SET "version" = EXCLUDED."version", "path" = EXCLUDED."path"';
    return $db->query($query, @$data{'package','version','path'});
  }
}

sub delete_package ($backend, $db, $package) {
  if ($backend eq 'sqlite') {
    return $db->delete('packages', {package => $package});
  } elsif ($backend eq 'pg') {
    return $db->delete('packages', {package => $package});
  }
}

my %valid_permission = (a => 1, m => 1, f => 1, c => 1);
sub prepare_06perms ($app) {
  my $perms_path = cache_file($app, 'modules/06perms.txt.gz', 1);
  
  my $fh = path($perms_path)->open('r');
  while (defined(my $line = readline $fh)) {
    last if $line =~ m/^\s*$/;
  }
  
  my $backend = $app->backend;
  my $db = _backend_db($app);
  
  my %perms;
  $perms{$_->{userid}}{$_->{package}} = 1 for @{existing_perms($backend, $db)};
  
  my $csv = Text::CSV_XS->new({binary => 1});
  $csv->bind_columns(\my $package, \my $userid, \my $best_permission);
  
  while ($csv->getline($fh)) {
    next unless length $package and length $userid and length $best_permission;
    unless (exists $valid_permission{$best_permission}) {
      $app->log->warn("06perms.txt: Found invalid permission type $best_permission for $userid on module $package");
      next;
    }
    my %perms_data = (package => $package, userid => $userid, best_permission => $best_permission);
    update_perms($backend, $db, \%perms_data);
    delete $perms{$userid}{$package};
  }
  
  foreach my $userid (keys %perms) {
    my @packages = keys %{$perms{$userid}};
    delete_perms($backend, $db, $userid, \@packages) if @packages;
  }
}

sub existing_perms ($backend, $db) {
  if ($backend eq 'sqlite') {
    return $db->select('perms', ['userid','package'])->hashes;
  } elsif ($backend eq 'pg') {
    return $db->select('perms', ['userid','package'])->hashes;
  }
}

sub update_perms ($backend, $db, $data) {
  if ($backend eq 'sqlite') {
    my $current = $db->select('perms', '*', {package => $data->{package}, userid => $data->{userid}})->hashes->first;
    return 1 if _keys_equal($data, $current, ['best_permission']);
    my $query = 'INSERT OR REPLACE INTO "perms" ("package","userid","best_permission") VALUES (?,?,?)';
    return $db->query($query, @$data{'package','userid','best_permission'});
  } elsif ($backend eq 'pg') {
    my $current = $db->select('perms', '*', {package => $data->{package}, userid => $data->{userid}})->hashes->first;
    return 1 if _keys_equal($data, $current, ['best_permission']);
    my $query = 'INSERT INTO "perms" ("package","userid","best_permission") VALUES (?,?,?)
      ON CONFLICT ("package","userid") DO UPDATE SET "best_permission" = EXCLUDED."best_permission"';
    return $db->query($query, @$data{'package','userid','best_permission'});
  }
}

sub delete_perms ($backend, $db, $userid, $packages) {
  return 0 unless @$packages;
  if ($backend eq 'sqlite') {
    return $db->delete('perms', {userid => $userid, package => {-in => $packages}});
  } elsif ($backend eq 'pg') {
    return $db->delete('perms', {userid => $userid, package => \['= ANY (?)', $packages]});
  }
}

sub prepare_00whois ($app) {
  my $whois_path = cache_file($app, 'authors/00whois.xml');
  
  my $contents = decode 'UTF-8', path($whois_path)->slurp;
  
  my $dom = Mojo::DOM->new->xml(1)->parse($contents);
  
  my $backend = $app->backend;
  my $db = _backend_db($app);
  
  my %authors = map { ($_ => 1) } @{existing_authors($backend, $db)};
  
  foreach my $author (@{$dom->find('cpanid')}) {
    next unless $author->at('type')->text eq 'author';
    my %details;
    foreach my $detail (qw(id fullname asciiname email homepage introduced has_cpandir)) {
      my $elem = $author->at($detail) // next;
      $details{$detail} = $elem->text;
    }
    next unless defined $details{id};
    $details{cpanid} = delete $details{id};
    update_author($backend, $db, \%details);
    delete $authors{$details{cpanid}};
  }
  
  delete_author($backend, $db, $_) for keys %authors;
}

sub existing_authors ($backend, $db) {
  if ($backend eq 'sqlite') {
    return $db->select('authors', ['cpanid'])->arrays->map(sub { $_->[0] });
  } elsif ($backend eq 'pg') {
    return $db->select('authors', ['cpanid'])->arrays->map(sub { $_->[0] });
  }
}

sub update_author ($backend, $db, $data) {
  if ($backend eq 'sqlite') {
    my $current = $db->select('authors', '*', {cpanid => $data->{cpanid}})->hashes->first;
    return 1 if _keys_equal($data, $current, [qw(fullname asciiname email homepage introduced has_cpandir)]);
    my $query = 'INSERT OR REPLACE INTO "authors" ("cpanid","fullname","asciiname","email","homepage","introduced","has_cpandir") VALUES (?,?,?,?,?,?,?)';
    return $db->query($query, @$data{'cpanid','fullname','asciiname','email','homepage','introduced','has_cpandir'});
  } elsif ($backend eq 'pg') {
    my $current = $db->select('authors', '*', {cpanid => $data->{cpanid}})->hashes->first;
    return 1 if _keys_equal($data, $current, [qw(fullname asciiname email homepage introduced has_cpandir)]);
    my $query = 'INSERT INTO "authors" ("cpanid","fullname","asciiname","email","homepage","introduced","has_cpandir") VALUES (?,?,?,?,?,?,?)
      ON CONFLICT ("cpanid") DO UPDATE SET "fullname" = EXCLUDED."fullname", "asciiname" = EXCLUDED."asciiname", "email" = EXCLUDED."email",
      "homepage" = EXCLUDED."homepage", "introduced" = EXCLUDED."introduced", "has_cpandir" = EXCLUDED."has_cpandir"';
    return $db->query($query, @$data{'cpanid','fullname','asciiname','email','homepage','introduced','has_cpandir'});
  }
}

sub delete_author ($backend, $db, $cpanid) {
  if ($backend eq 'sqlite') {
    return $db->delete('authors', {cpanid => $cpanid});
  } elsif ($backend eq 'pg') {
    return $db->delete('authors', {cpanid => $cpanid});
  }
}

sub _keys_equal ($first, $second, $keys) {
  return 0 unless defined $first and defined $second;
  foreach my $key (@$keys) {
    next if !defined $first->{$key} and !defined $second->{$key};
    return 0 unless defined $first->{$key} and defined $second->{$key} and $first->{$key} eq $second->{$key};
  }
  return 1;
}

sub _backend_db ($app) {
  my $backend = $app->backend;
  return $app->sqlite->db if $backend eq 'sqlite';
  return $app->pg->db if $backend eq 'pg';
  die "Unknown application backend $backend\n";
}

1;
