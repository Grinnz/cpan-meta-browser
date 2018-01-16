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
  my $cache_time = time;
  
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
  
  update_refreshed($backend, $db, 'packages', $cache_time);
}

sub existing_packages ($backend, $db) {
  if ($backend eq 'redis') {
    return $db->smembers('cpanmeta.packages');
  } else {
    return $db->select('packages', ['package'])->arrays->map(sub { $_->[0] });
  }
}

sub update_package ($backend, $db, $data) {
  my $current;
  if ($backend eq 'redis') {
    $current = {@{$db->hgetall("cpanmeta.package.$data->{package}")}};
  } else {
    $current = $db->select('packages', '*', {package => $data->{package}})->hashes->first;
  }
  return 1 if _keys_equal($data, $current, [qw(version path)]);
  if ($backend eq 'sqlite') {
    my $query = 'INSERT OR REPLACE INTO "packages" ("package","version","path") VALUES (?,?,?)';
    return $db->query($query, @$data{'package','version','path'});
  } elsif ($backend eq 'pg') {
    my $query = 'INSERT INTO "packages" ("package","version","path") VALUES (?,?,?)
      ON CONFLICT ("package") DO UPDATE SET "version" = EXCLUDED."version", "path" = EXCLUDED."path"';
    return $db->query($query, @$data{'package','version','path'});
  } elsif ($backend eq 'redis') {
    my $tx = $db->multi;
    $tx->sadd('cpanmeta.packages', $data->{package});
    $tx->hmset("cpanmeta.package.$data->{package}", %$data);
    my $package_lc = lc $data->{package};
    $tx->hset('cpanmeta.packages_lc', $package_lc => $data->{package});
    $tx->zadd('cpanmeta.packages_sorted', 0 => $package_lc);
    $tx->exec;
  }
}

sub delete_package ($backend, $db, $package) {
  if ($backend eq 'redis') {
    my $tx = $db->multi;
    $tx->srem('cpanmeta.packages', $package);
    $tx->del("cpanmeta.package.$package");
    my $package_lc = lc $package;
    $tx->hdel('cpanmeta.packages_lc', $package_lc);
    $tx->zrem('cpanmeta.packages_sorted', $package_lc);
    $tx->exec;
  } else {
    return $db->delete('packages', {package => $package});
  }
}

my %valid_permission = (a => 1, m => 1, f => 1, c => 1);
sub prepare_06perms ($app) {
  my $cache_time = time;
  
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
  
  update_refreshed($backend, $db, 'perms', $cache_time);
}

sub existing_perms ($backend, $db) {
  if ($backend eq 'redis') {
    return [map { +{userid => $_->[0], package => $_->[1]} } map { [split /\//, $_, 2] } @{$db->smembers('cpanmeta.perms')}];
  } else {
    return $db->select('perms', ['userid','package'])->hashes;
  }
}

sub update_perms ($backend, $db, $data) {
  my $current;
  if ($backend eq 'redis') {
    $current = {@{$db->hgetall("cpanmeta.perms.$data->{userid}/$data->{package}")}};
  } else {
    $current = $db->select('perms', '*', {package => $data->{package}, userid => $data->{userid}})->hashes->first;
  }
  return 1 if _keys_equal($data, $current, ['best_permission']);
  if ($backend eq 'sqlite') {
    my $query = 'INSERT OR REPLACE INTO "perms" ("package","userid","best_permission") VALUES (?,?,?)';
    return $db->query($query, @$data{'package','userid','best_permission'});
  } elsif ($backend eq 'pg') {
    my $query = 'INSERT INTO "perms" ("package","userid","best_permission") VALUES (?,?,?)
      ON CONFLICT ("package","userid") DO UPDATE SET "best_permission" = EXCLUDED."best_permission"';
    return $db->query($query, @$data{'package','userid','best_permission'});
  } elsif ($backend eq 'redis') {
    my $tx = $db->multi;
    $tx->sadd('cpanmeta.perms', "$data->{userid}/$data->{package}");
    $tx->hmset("cpanmeta.perms.$data->{userid}/$data->{package}", %$data);
    $tx->hset('cpanmeta.package_owners', $data->{package} => $data->{userid}) if $data->{best_permission} eq 'f';
    my $package_lc = lc $data->{package};
    my $userid_lc = lc $data->{userid};
    $tx->hset('cpanmeta.perms_packages_lc', $package_lc => $data->{package});
    $tx->hset('cpanmeta.perms_userids_lc', $userid_lc => $data->{userid});
    $tx->zadd('cpanmeta.perms_packages_sorted', 0 => $package_lc);
    $tx->zadd('cpanmeta.perms_userids_sorted', 0 => $userid_lc);
    $tx->zadd("cpanmeta.perms_userids_for_package.$data->{package}", 0 => $userid_lc);
    $tx->zadd("cpanmeta.perms_packages_for_userid.$data->{userid}", 0 => $package_lc);
    $tx->exec;
  }
}

sub delete_perms ($backend, $db, $userid, $packages) {
  if ($backend eq 'sqlite') {
    return $db->delete('perms', {userid => $userid, package => {-in => $packages}});
  } elsif ($backend eq 'pg') {
    return $db->delete('perms', {userid => $userid, package => \['= ANY (?)', $packages]});
  } elsif ($backend eq 'redis') {
    my $tx = $db->multi;
    my $userid_lc = lc $userid;
    $tx->zrem("cpanmeta.perms_userids_for_package.$_", $userid_lc) for @$packages;
    $tx->zrem("cpanmeta.perms_packages_for_userid.$userid", map { lc } @$packages) if @$packages;
    $tx->exec;
    
    $tx = $db->multi;
    
    foreach my $package (@$packages) {
      $tx->srem('cpanmeta.perms', "$userid/$package");
      
      $tx->watch("cpanmeta.perms.$userid/$package");
      if (($db->hget("cpanmeta.perms.$userid/$package", 'best_permission') // '') eq 'f') {
        $tx->hdel('cpanmeta.package_owners', $package);
      }
      
      $tx->del("cpanmeta.perms.$userid/$package");
      
      my $package_lc = lc $package;
      $tx->watch("cpanmeta.perms_userids_for_package.$package");
      unless ($db->zcard("cpanmeta.perms_userids_for_package.$package")) {
        $tx->hdel('cpanmeta.perms_packages_lc', $package_lc);
        $tx->zrem('cpanmeta.perms_packages_sorted', $package_lc);
      }
    }
    
    $tx->watch("cpanmeta.perms_packages_for_userid.$userid");
    unless ($db->zcard("cpanmeta.perms_packages_for_userid.$userid")) {
      $tx->hdel('cpanmeta.perms_userids_lc', $userid_lc);
      $tx->zrem('cpanmeta.perms_userids_sorted', $userid_lc);
    }
    
    $tx->exec;
  }
}

sub prepare_00whois ($app) {
  my $cache_time = time;
  
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
  
  update_refreshed($backend, $db, 'authors', $cache_time);
}

sub existing_authors ($backend, $db) {
  if ($backend eq 'redis') {
    return $db->smembers('cpanmeta.authors');
  } else {
    return $db->select('authors', ['cpanid'])->arrays->map(sub { $_->[0] });
  }
}

sub update_author ($backend, $db, $data) {
  my $current;
  if ($backend eq 'redis') {
    $current = {@{$db->hgetall("cpanmeta.author.$data->{cpanid}")}};
  } else {
    $current = $db->select('authors', '*', {cpanid => $data->{cpanid}})->hashes->first;
  }
  return 1 if _keys_equal($data, $current, [qw(fullname asciiname email homepage introduced has_cpandir)]);
  if ($backend eq 'sqlite') {
    my $query = 'INSERT OR REPLACE INTO "authors" ("cpanid","fullname","asciiname","email","homepage","introduced","has_cpandir") VALUES (?,?,?,?,?,?,?)';
    return $db->query($query, @$data{'cpanid','fullname','asciiname','email','homepage','introduced','has_cpandir'});
  } elsif ($backend eq 'pg') {
    my $query = 'INSERT INTO "authors" ("cpanid","fullname","asciiname","email","homepage","introduced","has_cpandir") VALUES (?,?,?,?,?,?,?)
      ON CONFLICT ("cpanid") DO UPDATE SET "fullname" = EXCLUDED."fullname", "asciiname" = EXCLUDED."asciiname", "email" = EXCLUDED."email",
      "homepage" = EXCLUDED."homepage", "introduced" = EXCLUDED."introduced", "has_cpandir" = EXCLUDED."has_cpandir"';
    return $db->query($query, @$data{'cpanid','fullname','asciiname','email','homepage','introduced','has_cpandir'});
  } elsif ($backend eq 'redis') {
    my $tx = $db->multi;
    $tx->sadd('cpanmeta.authors', $data->{cpanid});
    $tx->hmset("cpanmeta.author.$data->{cpanid}", %$data);
    my $cpanid_lc = lc $data->{cpanid};
    $tx->hset('cpanmeta.cpanids_lc', $cpanid_lc => $data->{cpanid});
    $tx->zadd('cpanmeta.cpanids_sorted', 0 => $cpanid_lc);
    $tx->exec;
  }
}

sub delete_author ($backend, $db, $cpanid) {
  if ($backend eq 'redis') {
    my $tx = $db->multi;
    $tx->srem('cpanmeta.authors', $cpanid);
    $tx->del("cpanmeta.author.$cpanid");
    my $cpanid_lc = lc $cpanid;
    $tx->hdel('cpanmeta.cpanids_lc', $cpanid_lc);
    $tx->zrem('cpanmeta.cpanids_sorted', $cpanid_lc);
    $tx->exec;
  } else {
    return $db->delete('authors', {cpanid => $cpanid});
  }
}

sub update_refreshed ($backend, $db, $type, $time) {
  if ($backend eq 'sqlite') {
    my $query = q{INSERT OR REPLACE INTO "refreshed" ("type","last_updated") VALUES (?,datetime(?, 'unixepoch'))};
    return $db->query($query, $type, $time);
  } elsif ($backend eq 'pg') {
    my $query = 'INSERT INTO "refreshed" ("type","last_updated") VALUES (?,to_timestamp(?))
      ON CONFLICT ("type") DO UPDATE SET "last_updated" = EXCLUDED."last_updated"';
    return $db->query($query, $type, $time);
  } elsif ($backend eq 'redis') {
    $db->hset('cpanmeta.refreshed', $type => $time);
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
  return $app->redis if $backend eq 'redis';
  die "Unknown application backend $backend\n";
}

1;
