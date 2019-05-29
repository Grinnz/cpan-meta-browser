requires 'perl' => '5.020';
requires 'lib::relative';
requires 'CPAN::DistnameInfo';
requires 'Getopt::Long';
requires 'HTTP::Tiny' => '0.039';
requires 'IO::Socket::SSL';
requires 'IO::Uncompress::Gunzip';
requires 'Mojolicious' => '7.51';
requires 'Mojolicious::Plugin::AccessLog';
requires 'Mojo::Log::Role::Clearable';
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
