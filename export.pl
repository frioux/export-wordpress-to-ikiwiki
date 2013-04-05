#!/usr/bin/env perl

use 5.16.1;
use warnings;

use XML::Simple;
use DateTime::Format::Strptime;
use HTML::WikiConverter;

die "usage: $0 name email import_file subdir branch | git-fast-import"
   unless @ARGV == 4 or @ARGV == 5;

my ($name, $email, $file, $subdir, $branch) = @ARGV;

my $parser = DateTime::Format::Strptime->new(
   pattern => '%F %T',
   time_zone => 'UTC',
);

my $converter = HTML::WikiConverter->new(
   dialect              => 'Markdown',
   link_style           => 'inline',
   unordered_list_style => 'dash',
   image_style          => 'inline',
   image_tag_fallback   => 0,
);

my $debug = '';
for my $x (grep $_->{'wp:status'} eq 'publish', @{XMLin($file)->{channel}{item}}) {
   my $stub = $x =~ m<([^/]+)\/$>
      ? $1
      : lc($x->{title} =~ s/\W/-/gr =~ s/-$//r)
   ;

   my $msg = qq($x->{title}\n\nfrom WordPress [$x->{guid}{content}]);
   my $timestamp = $parser->parse_datetime($x->{'wp:post_date_gmt'})->epoch;
   my $c = $x->{category};
   $c = [$c] if ref $c && ref $c ne 'ARRAY';
   my $body = $x->{'content:encoded'};
   utf8::encode($body);
   #$body =~ s(\n)(<br>)g;

   # I know I know you can't parse XML with regular expressions.  Go find a real
   # parser and send me a patch
   my $in_code = 0;
   my $start_code = qr(<pre[^>]*>);
   my $had_code = $body =~ $start_code;
   $body =~ s(<code[^>]*>)(<pre>)g;
   $body =~ s(</code>)(</pre>)g;

   my @tokens =
      map {; split qr[(?=<pre>)] }
      map {; split qr[</pre>\K] }
      split /\n\n/,
      $body;

   use Data::Dumper::Concise;
   #$debug .= $body;
   #warn Dumper(\@tokens);
   $body = '';
   my $end_code = qr(</pre>);
   my @new_tokens;
   TOKEN:
   for my $t (@tokens) {
      if (
         ($in_code && $t !~ $end_code) ||
         ($t =~ $start_code && $t =~ $end_code)
      ) {
         #$t = "\n\n$t"
      } elsif ($t =~ $start_code) {
         $in_code = 1;
      } elsif ($t =~ $end_code) {
         $in_code = 0;
      } else {
         $t = "<p>$t</p>"
      }
      push @new_tokens, $t
   }

   #warn Dumper(\@new_tokens);
   $body = join "\n\n", @new_tokens;
   #$body =~ s(<code[^>]*>)(<pre>)g; $body =~ s(</code>)(</pre>)g;
   #$body = join qq{\n\n}, map {; "<p>$_</p>" }

   my $content =
      sprintf(qq([[!meta title="%s"]]\n), $x->{title} =~ s/"/\\"/gr) .
      qq([[!meta date="$timestamp"]]\n) .
      $converter->html2wiki($body) . "\n\n" .
      join("\n",
         map '[[!tag ' . s/ /-/r . ']]',
         grep $_ ne 'uncategorized',
         map $_->{nicename},
         @$c,
      );
   print "commit refs/heads/$branch\n";
   print "committer $name <$email> $timestamp +0000\n";
   print 'data ' . length($msg) . "\n";
   print $msg . "\n";
   print "M 644 inline $subdir/$stub.mdwn\n";
   print 'data ' . length($content) . "\n";
   print $content . "\n";
}
#print $debug;
