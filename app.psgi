use Plack::Builder;
use Plack::Request;
use Git::Repository;
use Git::Repository::Command;
use CGI;
use Encode;
binmode STDOUT, ':utf8';

my $HEADER = ['content-type' => 'text/html'];
my $cgi = CGI->new;

sub base_top() {
<<_EOF_;
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>git diff</title>
    <link type="text/css" rel="stylesheet" href="/css/gitweb.css">
  </head>
  <body>
_EOF_
}

sub base_bottom() {
<<_EOF_;
  </body>
</html>
_EOF_
}


sub format_diff_line {
    my ($line, $diff_class, $from, $to) = @_;

    if (ref($line)) {
        $line = $$line;
    } else {
        chomp $line;
        $line = untabify($line);

        if ($from && $to && $line =~ m/^\@{2} /) {
            $line = format_unidiff_chunk_header($line, $from, $to);
        } elsif ($from && $to && $line =~ m/^\@{3}/) {
            $line = format_cc_diff_chunk_header($line, $from, $to);
        } else {
            $line = esc_html($line, -nbsp=>1);
        }
    }

    my $diff_classes = "diff";
    $diff_classes .= " $diff_class" if ($diff_class);
    $line = "<div class=\"$diff_classes\">$line</div>\n";

    return $line;
}

# escape tabs (convert tabs to spaces)
sub untabify {
    my $line = shift;

    while ((my $pos = index($line, "\t")) != -1) {
        if (my $count = (8 - ($pos % 8))) {
            my $spaces = ' ' x $count;
            $line =~ s/\t/$spaces/;
        }
    }

    return $line;
}

# decode sequences of octets in utf8 into Perl's internal form,
# which is utf-8 with utf8 flag set if needed.  gitweb writes out
# in utf-8 thanks to "binmode STDOUT, ':utf8'" at beginning
sub to_utf8 {
    my $str = shift;
    return undef unless defined $str;

    if (utf8::is_utf8($str) || utf8::decode($str)) {
        return $str;
    } else {
        return decode($fallback_encoding, $str, Encode::FB_DEFAULT);
    }
}

# assumes that $from and $to are defined and correctly filled,
# and that $line holds a line of chunk header for unified diff
sub format_unidiff_chunk_header {
    my ($line, $from, $to) = @_;

    my ($from_text, $from_start, $from_lines, $to_text, $to_start, $to_lines, $section) =
        $line =~ m/^\@{2} (-(\d+)(?:,(\d+))?) (\+(\d+)(?:,(\d+))?) \@{2}(.*)$/;

    $from_lines = 0 unless defined $from_lines;
    $to_lines   = 0 unless defined $to_lines;

    if ($from->{'href'}) {
        $from_text = $cgi->a({-href=>"$from->{'href'}#l$from_start",
                             -class=>"list"}, $from_text);
    }
    if ($to->{'href'}) {
        $to_text   = $cgi->a({-href=>"$to->{'href'}#l$to_start",
                             -class=>"list"}, $to_text);
    }
    $line = "<span class=\"chunk_info\">@@ $from_text $to_text @@</span>" .
            "<span class=\"section\">" . esc_html($section, -nbsp=>1) . "</span>";
    return $line;
}

# assumes that $from and $to are defined and correctly filled,
# and that $line holds a line of chunk header for combined diff
sub format_cc_diff_chunk_header {
    my ($line, $from, $to) = @_;

    my ($prefix, $ranges, $section) = $line =~ m/^(\@+) (.*?) \@+(.*)$/;
    my (@from_text, @from_start, @from_nlines, $to_text, $to_start, $to_nlines);

    @from_text = split(' ', $ranges);
    for (my $i = 0; $i < @from_text; ++$i) {
        ($from_start[$i], $from_nlines[$i]) =
            (split(',', substr($from_text[$i], 1)), 0);
    }

    $to_text   = pop @from_text;
    $to_start  = pop @from_start;
    $to_nlines = pop @from_nlines;

    $line = "<span class=\"chunk_info\">$prefix ";
    for (my $i = 0; $i < @from_text; ++$i) {
        if ($from->{'href'}[$i]) {
            $line .= $cgi->a({-href=>"$from->{'href'}[$i]#l$from_start[$i]",
                              -class=>"list"}, $from_text[$i]);
        } else {
            $line .= $from_text[$i];
        }
        $line .= " ";
    }
    if ($to->{'href'}) {
        $line .= $cgi->a({-href=>"$to->{'href'}#l$to_start",
                          -class=>"list"}, $to_text);
    } else {
        $line .= $to_text;
    }
    $line .= " $prefix</span>" .
             "<span class=\"section\">" . esc_html($section, -nbsp=>1) . "</span>";
    return $line;
}

# replace invalid utf8 character with SUBSTITUTION sequence
sub esc_html {
    my $str = shift;
    my %opts = @_;

    return undef unless defined $str;

    $str = to_utf8($str);
    $str = $cgi->escapeHTML($str);
    if ($opts{'-nbsp'}) {
        $str =~ s/ /&nbsp;/g;
    }
    $str =~ s|([[:cntrl:]])|(($1 ne "\t") ? quot_cec($1) : $1)|eg;
    return $str;
}

sub print_diff_lines {
    my ($ctx, $rem, $add, $num_parents) = @_;
    my $is_combined = $num_parents > 1;

    ($ctx, $rem, $add) = format_ctx_rem_add_lines($ctx, $rem, $add,
            $num_parents);

    print_sidebyside_diff_lines($ctx, $rem, $add);
}

# HTML-format diff context, removed and added lines.
sub format_ctx_rem_add_lines {
    my ($ctx, $rem, $add, $num_parents) = @_;
    my (@new_ctx, @new_rem, @new_add);
    my $can_highlight = 0;
    my $is_combined = ($num_parents > 1);

    # Highlight if every removed line has a corresponding added line.
    if (@$add > 0 && @$add == @$rem) {
        $can_highlight = 1;

        # Highlight lines in combined diff only if the chunk contains
        # diff between the same version, e.g.
        #
        #    - a
        #   -  b
        #    + c
        #   +  d
        #
        # Otherwise the highlightling would be confusing.
        if ($is_combined) {
            for (my $i = 0; $i < @$add; $i++) {
                my $prefix_rem = substr($rem->[$i], 0, $num_parents);
                my $prefix_add = substr($add->[$i], 0, $num_parents);

                $prefix_rem =~ s/-/+/g;

                if ($prefix_rem ne $prefix_add) {
                    $can_highlight = 0;
                    last;
                }
            }
        }
    }

    if ($can_highlight) {
        for (my $i = 0; $i < @$add; $i++) {
            my ($line_rem, $line_add) = format_rem_add_lines_pair(
                    $rem->[$i], $add->[$i], $num_parents);
            push @new_rem, $line_rem;
            push @new_add, $line_add;
        }
    } else {
        @new_rem = map { format_diff_line($_, 'rem') } @$rem;
        @new_add = map { format_diff_line($_, 'add') } @$add;
    }

    @new_ctx = map { format_diff_line($_, 'ctx') } @$ctx;

    return (\@new_ctx, \@new_rem, \@new_add);
}

# Format removed and added line, mark changed part and HTML-format them.
# Implementation is based on contrib/diff-highlight
sub format_rem_add_lines_pair {
    my ($rem, $add, $num_parents) = @_;

    # We need to untabify lines before split()'ing them;
    # otherwise offsets would be invalid.
    chomp $rem;
    chomp $add;
    $rem = untabify($rem);
    $add = untabify($add);

    my @rem = split(//, $rem);
    my @add = split(//, $add);
    my ($esc_rem, $esc_add);
    # Ignore leading +/- characters for each parent.
    my ($prefix_len, $suffix_len) = ($num_parents, 0);
    my ($prefix_has_nonspace, $suffix_has_nonspace);

    my $shorter = (@rem < @add) ? @rem : @add;
    while ($prefix_len < $shorter) {
        last if ($rem[$prefix_len] ne $add[$prefix_len]);

        $prefix_has_nonspace = 1 if ($rem[$prefix_len] !~ /\s/);
        $prefix_len++;
    }

    while ($prefix_len + $suffix_len < $shorter) {
        last if ($rem[-1 - $suffix_len] ne $add[-1 - $suffix_len]);

        $suffix_has_nonspace = 1 if ($rem[-1 - $suffix_len] !~ /\s/);
        $suffix_len++;
    }

    # Mark lines that are different from each other, but have some common
    # part that isn't whitespace.  If lines are completely different, don't
    # mark them because that would make output unreadable, especially if
    # diff consists of multiple lines.
    if ($prefix_has_nonspace || $suffix_has_nonspace) {
        $esc_rem = esc_html_hl_regions($rem, 'marked',
                [$prefix_len, @rem - $suffix_len], -nbsp=>1);
        $esc_add = esc_html_hl_regions($add, 'marked',
                [$prefix_len, @add - $suffix_len], -nbsp=>1);
    } else {
        $esc_rem = esc_html($rem, -nbsp=>1);
        $esc_add = esc_html($add, -nbsp=>1);
    }

    return format_diff_line(\$esc_rem, 'rem'),
           format_diff_line(\$esc_add, 'add');
}

# Highlight selected fragments of string, using given CSS class,
# and escape HTML.  It is assumed that fragments do not overlap.
# Regions are passed as list of pairs (array references).
#
# Example: esc_html_hl_regions("foobar", "mark", [ 0, 3 ]) returns
# '<span class="mark">foo</span>bar'
sub esc_html_hl_regions {
    my ($str, $css_class, @sel) = @_;
    my %opts = grep { ref($_) ne 'ARRAY' } @sel;
    @sel     = grep { ref($_) eq 'ARRAY' } @sel;
    return esc_html($str, %opts) unless @sel;

    my $out = '';
    my $pos = 0;

    for my $s (@sel) {
        my ($begin, $end) = @$s;

        # Don't create empty <span> elements.
        next if $end <= $begin;

        my $escaped = esc_html(substr($str, $begin, $end - $begin),
                               %opts);

        $out .= esc_html(substr($str, $pos, $begin - $pos), %opts)
            if ($begin - $pos > 0);
        $out .= $cgi->span({-class => $css_class}, $escaped);

        $pos = $end;
    }
    $out .= esc_html(substr($str, $pos), %opts)
        if ($pos < length($str));

    return $out;
}


sub print_sidebyside_diff_lines {
    my ($ctx, $rem, $add) = @_;

    $string = '';
    # print context block before add/rem block
    if (@$ctx) {
        $string .= join '',
            '<div class="chunk_block ctx">',
                '<div class="old">',
                @$ctx,
                '</div>',
                '<div class="new">',
                @$ctx,
                '</div>',
            '</div>';
    }

    if (!@$add) {
        # pure removal
        $string .= join '',
            '<div class="chunk_block rem">',
                '<div class="old">',
                @$rem,
                '</div>',
            '</div>';
    } elsif (!@$rem) {
        # pure addition
        $string .= join '',
            '<div class="chunk_block add">',
                '<div class="new">',
                @$add,
                '</div>',
            '</div>';
    } else {
        $string .= join '',
            '<div class="chunk_block chg">',
                '<div class="old">',
                @$rem,
                '</div>',
                '<div class="new">',
                @$add,
                '</div>',
            '</div>';
    }
    return $string;
}



sub app {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my $dir = $req->param('dir');

    unless ($dir && -d $dir) {
        return ['404', $HEADER, ['not found']];
    }

    $r = Git::Repository->new(work_tree => $dir);
    my $cmd = Git::Repository::Command->new($r, 'diff');

    my $log = $cmd->stdout;
    my @diff_line_classifier = (
        { regexp => qr/^\@\@{1} /, class => "chunk_header"},
        { regexp => qr/^\\/,               class => "incomplete"  },
        { regexp => qr/^ {1}/,     class => "ctx" },
        # classifier for context must come before classifier add/rem,
        # or we would have to use more complicated regexp, for example
        # qr/(?= {0,$m}\+)[+ ]{$num_sign}/, where $m = $num_sign - 1;
        { regexp => qr/^[+ ]{1}/,   class => "add" },
        { regexp => qr/^[- ]{1}/,   class => "rem" },
    );

    my @chunk;
    while (<$log>) {
        chomp($_);
        for my $clsfy (@diff_line_classifier) {
            if ($_ =~ $clsfy->{'regexp'}) {
                push @chunk, [$clsfy->{'class'}, $_];
                last;
            }
        }
    }
    $cmd->close();

    my $html = '';
    my $prev_class = '';
    my (@ctx, @rem, @add);
    my (%from, %to);

    for my $line_info (@chunk) {
        my ($class, $line) = @$line_info;

        # print chunk headers
        if ($class && $class eq 'chunk_header') {
            $html .= format_diff_line($line, $class, $from, $to);
            next;
        }

        ## print from accumulator when have some add/rem lines or end
        # of chunk (flush context lines), or when have add and rem
        # lines and new block is reached (otherwise add/rem lines could
        # be reordered)
        if (!$class || ((@rem || @add) && $class eq 'ctx') ||
            (@rem && @add && $class ne $prev_class)) {
            $html .= print_diff_lines(\@ctx, \@rem, \@add, 1);
            @ctx = @rem = @add = ();
        }

        ## adding lines to accumulator
        # guardian value
        last unless $line;
        # rem, add or change
        if ($class eq 'rem') {
            push @rem, $line;
        } elsif ($class eq 'add') {
            push @add, $line;
        }
        # context line
        if ($class eq 'ctx') {
            push @ctx, $line;
        }

        $prev_class = $class;
    }

    return ['200', $HEADER, [
        base_top(),
        encode_utf8($html),
        base_bottom(),
    ]];
}


builder {
    enable "ContentLength";
    enable 'Static',
        path => qr!^/(?:(?:css|js|images)/|favicon\.ico$)!,
        root => './statics/';
    mount '/diff' => \&app;
    mount '/' => sub {
        return [ 200, [ 'Content-Type' => 'text/plain' ], [ 'hello' ] ];
    };
};

