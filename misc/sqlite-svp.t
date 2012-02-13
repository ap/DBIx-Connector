use strict;
use warnings;
use Test::More tests => 3;

use DBIx::Connector;
use Scalar::Util qw(blessed);

unlink 'test.sqlite';

my $conn = DBIx::Connector->new(
  'dbi:SQLite:test.sqlite',
  undef,
  undef,
  { RaiseError => 1 },
);

$conn->txn(sub {
  my ($dbh) = @_;
  $dbh->do("CREATE TABLE stuff (foo NOT NULL);");
});

$conn->txn(fixup => sub {
  my ($dbh) = @_;
  $dbh->do("INSERT INTO stuff (foo) VALUES (1);");

  my $token = \do { my $x };

  my $ok = eval {
    $conn->svp(sub {
      my ($dbh) = @_;
      $dbh->do("INSERT INTO stuff (foo) VALUES (2)");
      die $token;
    });
    1;
  };
  my $error = $@;

  ok( ! $ok, "we didn't survive our svp");
  ok(
    (ref $error  && ! blessed $error && $error == $token),
    "we got the expected error, too"
  ) or diag "got error: $error";

  $dbh->do("INSERT INTO stuff (foo) VALUES (3);");
});

$conn->txn(sub {
  my ($dbh) = @_;
  my $rows = $dbh->selectcol_arrayref("SELECT foo FROM stuff ORDER BY foo");
  is(@$rows, 2, "we inserted 2 rows");
  is_deeply($rows, [ 1, 3 ], "...and they're [1],[3] - 2 was lost in the svp");
});

done_testing;
