#!/usr/bin/env perl

use 5.16.1;
use warnings;

use XML::Simple;
use DateTime::Format::Strptime;
use HTML::WikiConverter;
use LWP::UserAgent;
use Try::Tiny;

die "usage: $0 import_file subdir [branch] | git-fast-import"
   unless @ARGV == 2 or @ARGV == 3;

chomp(my $name = qx(git config --get user.name));
chomp(my $email = qx(git config --get user.email));

my ($file, $subdir, $branch) = @ARGV;

my $date_parser = DateTime::Format::Strptime->new(
   pattern => '%F %T',
   time_zone => 'UTC',
);

POST:
for my $x (grep $_->{'wp:status'} eq 'publish', @{XMLin($file)->{channel}{item}}) {
   my $stub = $x =~ m<([^/]+)\/$>
      ? $1
      : lc($x->{title} =~ s/\W/-/gr =~ s/-$//r)
   ;

   my $msg = qq($x->{title}\n\nfrom WordPress [$x->{guid}{content}]);
   my $timestamp = $date_parser
      ->parse_datetime($x->{'wp:post_date_gmt'})
      ->epoch;

   my $c = $x->{category};
   $c = [$c] if ref $c && ref $c ne 'ARRAY';

   my $content =
      sprintf(qq([[!meta title="%s"]]\n), $x->{title} =~ s/"/\\"/gr) .
      qq([[!meta date="$timestamp"]]\n) .
      convert_content($x->{'content:encoded'}) . "\n\n" .
      join("\n",
         map '[[!tag ' . s/ /-/r . ']]',
         grep $_ ne 'uncategorized',
         map $_->{nicename},
         @$c,
      );

   say "commit refs/heads/$branch";
   say "committer $name <$email> $timestamp +0000";
   say 'data ' . length $msg ;
   say $msg;
   say "M 644 inline $subdir/$stub.mdwn";
   say 'data ' . length $content;
   say $content;

   get_comments($x->{link})
      if $x->{'wp:post_type'} eq 'post'
}

sub get_comments {
   my ($url, $post) = @_;

   state $ua = LWP::UserAgent->new;

   #$url =~ s(\?p=)(archive/);
   warn "\nxxx: $url/feed\n";
   my $content = $ua->get("$url/feed")->decoded_content;
   my $first;
   my $bail;
   my $decoded =
      try { XMLin($content, ForceArray => ['item']) }
      catch { $bail = 1 };

   return if $bail;

   COMMENT:
   for my $x (@{$decoded->{channel}{item}}) {
      warn $content unless $first;
      $first++;
      use Devel::Dwarn;
      Dwarn {
         content => convert_content($x->{'content:encoded'}),
         author  => $x->{'dc:creator'},
         guid    => $x->{guid}{content},
         date    => $x->{pubDate},
      };
   }
}

sub convert_content {
   my $body = shift;

   utf8::encode($body);

   state $converter = HTML::WikiConverter->new(
      dialect              => 'Markdown',
      link_style           => 'inline',
      unordered_list_style => 'dash',
      image_style          => 'inline',
      image_tag_fallback   => 0,
   );

   # I know I know you can't parse XML with regular expressions.  Go find a real
   # parser and send me a patch
   my $in_code = 0;

   my $start_code = qr(<pre[^>]*>);
   my $end_code = qr(</pre>);

   $body =~ s(&#(?:8217|039);)(')g;
   $body =~ s(&(?:quot|#822[01]);)(")g;
   $body =~ s(&lt;)(<)g;
   $body =~ s(&gt;)(>)g;
   $body =~ s(&amp;)(&)g;
   $body =~ s(&#8230;)(...)g;
   $body =~ s(&#821[12];)(-)g;
   $body =~ s(&#8216;)(')g;
   $body =~ s(&#8242;)(')g;
   $body =~ s(&infin;)(∞)g;
   #$body =~ s(&#41;)(@)g;
   $body =~ s(&nbsp;)()g;
   $body =~ s(<code[^>]*>)(<pre>)g;
   $body =~ s(</code>)(</pre>)g;

   my @tokens =
      map {; split qr[(?=<pre>)] }
      map {; split qr[</pre>\K] }
      split /\n\n/,
      $body;

   my @new_tokens;
   for my $t (@tokens) {
      if (
         ($in_code && $t !~ $end_code) ||
         ($t =~ $start_code && $t =~ $end_code)
      ) {
         # do nothing
      } elsif ($t =~ $start_code) {
         $in_code = 1;
      } elsif ($t =~ $end_code) {
         $in_code = 0;
      } else {
         die "$t !!! '$1'" if $t =~ m/&([^;\s]+);/ && $1 !~ /[lg]t/;

         $t = "<p>$t</p>"
      }
      push @new_tokens, $t
   }

   $converter->html2wiki(join "\n\n", @new_tokens)
}
