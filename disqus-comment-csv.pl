#!/usr/bin/env perl

use 5.16.1;
use warnings;

use XML::Simple;
use URI;

my ($file) = @ARGV;

for my $x (grep $_->{'wp:status'} eq 'publish', @{XMLin($file)->{channel}{item}}) {
   warn " -- mapping post: $x->{title}\n";

   my $stub = $x =~ m<([^/]+)\/$>
      ? $1
      : lc($x->{title} =~ s/\W/-/gr =~ s/-+/-/gr =~ s/-$//r =~ s/^-//r)
   ;

   for my $http (qw(http https)) {
      my $from = URI->new($x->{link});
      $from->scheme($http);
      my $to = URI->new("https://blog.afoolishmanifesto.com/posts/$stub/");
      print "$from, $to\r\n";
   }
}

