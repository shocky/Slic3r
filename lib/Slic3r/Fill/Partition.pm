package Slic3r::Fill::Partition;
use Moo;

extends 'Slic3r::Fill::Base';

use Slic3r::Geometry qw(X1 Y1 X2 Y2 A B X Y scale unscale scaled_epsilon);

sub fill_surface {
    my $self = shift;
    my ($surface, %params) = @_;
    
    # rotate polygons so that we can work with vertical lines here
    my $expolygon = $surface->expolygon->clone;
    my $rotate_vector = $self->infill_direction($surface);
    $self->rotate_points($expolygon, $rotate_vector);
    
    my ($expolygon_off) = $expolygon->offset_ex(scale $params{flow_spacing}/2);
    return {} if !$expolygon_off;  # skip some very small polygons (which shouldn't arrive here)
    my $bounding_box = [ $expolygon->bounding_box ];
    
    my $min_spacing = scale $params{flow_spacing};
    my $wall_count = 4;
    my $distance_between_lines = $min_spacing / $params{density};
    my $line_oscillation = $distance_between_lines - $min_spacing;
   
    my $flow_spacing = unscale $self->adjust_solid_spacing(
            width       => $bounding_box->[X2] - $bounding_box->[X1],
            distance    => $distance_between_lines,
        );
   
    my $skip_lines = 0; 
    my $x = $bounding_box->[X1];
    my @vertical_lines = ();
    for (my $i = 0; $x <= $bounding_box->[X2] + scaled_epsilon; $i++) {
        my $vertical_line = Slic3r::Line->new([$x, $bounding_box->[Y2]], [$x, $bounding_box->[Y1]]);
        push @vertical_lines, $vertical_line;

	if ($skip_lines < $wall_count) {
          $x += $min_spacing;
	  $skip_lines++;
	} else {
	  $x += $distance_between_lines * $wall_count; 
	  $skip_lines = 0;
  	}
	#$x += $distance_between_lines;
    }
    
    # clip paths against a slightly offsetted expolygon, so that the first and last paths
    # are kept even if the expolygon has vertical sides
    my @paths = @{ Boost::Geometry::Utils::polygon_multi_linestring_intersection(
        +($expolygon->offset_ex(scaled_epsilon))[0],  # TODO: we should use all the resulting expolygons and clip the linestrings to a multipolygon object
        [ @vertical_lines ],
    ) };
    
    # connect lines
    unless ($params{dont_connect}) {
        my $collection = Slic3r::Polyline::Collection->new(
            polylines => [ map Slic3r::Polyline->new(@$_), @paths ],
        );
        @paths = ();
        
	my $is_line_pattern = 0;
        my $tolerance = 10 * scaled_epsilon;
        my $diagonal_distance = $distance_between_lines * 5;
        my $can_connect = $is_line_pattern
            ? sub {
                ($_[X] >= ($distance_between_lines - $line_oscillation) - $tolerance) && ($_[X] <= ($distance_between_lines + $line_oscillation) + $tolerance)
                    && $_[Y] <= $diagonal_distance
            }
            : sub { abs($_[X] - $distance_between_lines) <= $tolerance && $_[Y] <= $diagonal_distance };
        
        foreach my $path ($collection->chained_path) {
            if (@paths) {
                my @distance = map abs($path->[0][$_] - $paths[-1][-1][$_]), (X,Y);
                
                # TODO: we should also check that both points are on a fill_boundary to avoid 
                # connecting paths on the boundaries of internal regions
                if ($can_connect->(@distance, $paths[-1][-1], $path->[0])
                    && $expolygon_off->encloses_line(Slic3r::Line->new($paths[-1][-1], $path->[0]), $tolerance)) {
                    push @{$paths[-1]}, @$path;
                    next;
                }
            }
            push @paths, $path;
        }
    }
    
    # paths must be rotated back
    $self->rotate_points_back(\@paths, $rotate_vector);
    
    return { flow_spacing => $flow_spacing }, @paths;
}

1;
