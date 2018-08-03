requires 'perl' => '5.020';
requires 'experimental';
requires 'lib::relative';
requires 'Getopt::Long';
requires 'HTTP::Tiny' => '0.039';
requires 'IO::Socket::SSL';
requires 'IO::Uncompress::Gunzip';
requires 'Mojolicious' => '7.29';
requires 'Mojolicious::Plugin::AccessLog';
requires 'Mojo::JSON::MaybeXS';
requires 'Syntax::Keyword::Try' => '0.04';
requires 'Text::CSV_XS';

feature 'pg', 'PostgreSQL backend', sub {
  requires 'Mojo::Pg' => '4.08';
};

feature 'sqlite', 'SQLite backend', sub {
  requires 'Mojo::SQLite' => '3.000';
};

feature 'redis', 'Redis backend', sub {
  requires 'Mojo::Redis' => '3.07';
  recommends 'Protocol::Redis::XS';
};
