package Slic3r::Layer::Region::Island;
use Moo;

has 'region' => (
    is          => 'ro',
    weak_ref    => 1,
    required    => 1,
    handles     => [qw()],
);

# collection of polygons or polylines representing thin infill regions that
# need to be filled with a medial axis
has 'thin_fills' => (is => 'rw', default => sub { [] });

# collection of surfaces for infill generation
has 'fill_surfaces' => (is => 'rw', default => sub { [] });

# ordered collection of extrusion paths/loops to build all perimeters
has 'perimeters' => (is => 'rw', default => sub { [] });

# ordered collection of extrusion paths to fill surfaces
has 'fills' => (is => 'rw', default => sub { [] });

sub prepare_fill_surfaces {
    my $self = shift;
    
    # if no solid layers are requested, turn top/bottom surfaces to internal
    if ($Slic3r::Config->top_solid_layers == 0) {
        $_->surface_type(S_TYPE_INTERNAL) for grep $_->surface_type == S_TYPE_TOP, @{$self->fill_surfaces};
    }
    if ($Slic3r::Config->bottom_solid_layers == 0) {
        $_->surface_type(S_TYPE_INTERNAL) for grep $_->surface_type == S_TYPE_BOTTOM, @{$self->fill_surfaces};
    }
        
    # turn too small internal regions into solid regions according to the user setting
    {
        my $min_area = scale scale $Slic3r::Config->solid_infill_below_area; # scaling an area requires two calls!
        my @small = grep $_->surface_type == S_TYPE_INTERNAL && $_->expolygon->contour->area <= $min_area, @{$self->fill_surfaces};
        $_->surface_type(S_TYPE_INTERNALSOLID) for @small;
        Slic3r::debugf "identified %d small solid surfaces at layer %d\n", scalar(@small), $self->id if @small > 0;
    }
}

sub process_external_surfaces {
    my $self = shift;
    
    # enlarge top and bottom surfaces
    {
        # get all external surfaces
        my @top     = grep $_->surface_type == S_TYPE_TOP, @{$self->fill_surfaces};
        my @bottom  = grep $_->surface_type == S_TYPE_BOTTOM, @{$self->fill_surfaces};
        
        # offset them and intersect the results with the actual fill boundaries
        my $margin = scale 3;  # TODO: ensure this is greater than the total thickness of the perimeters
        @top = @{intersection_ex(
            [ Slic3r::Geometry::Clipper::offset([ map $_->p, @top ], +$margin) ],
            [ map $_->p, @{$self->fill_surfaces} ],
            undef,
            1,  # to ensure adjacent expolygons are unified
        )};
        @bottom = @{intersection_ex(
            [ Slic3r::Geometry::Clipper::offset([ map $_->p, @bottom ], +$margin) ],
            [ map $_->p, @{$self->fill_surfaces} ],
            undef,
            1,  # to ensure adjacent expolygons are unified
        )};
        
        # give priority to bottom surfaces
        @top = @{diff_ex(
            [ map @$_, @top ],
            [ map @$_, @bottom ],
        )};
        
        # generate new surfaces
        my @new_surfaces = ();
        push @new_surfaces, map Slic3r::Surface->new(
                expolygon       => $_,
                surface_type    => S_TYPE_TOP,
            ), @top;
        push @new_surfaces, map Slic3r::Surface->new(
                expolygon       => $_,
                surface_type    => S_TYPE_BOTTOM,
            ), @bottom;
        
        # subtract the new top surfaces from the other non-top surfaces and re-add them
        my @other = grep $_->surface_type != S_TYPE_TOP && $_->surface_type != S_TYPE_BOTTOM, @{$self->fill_surfaces};
        foreach my $group (Slic3r::Surface->group(@other)) {
            push @new_surfaces, map Slic3r::Surface->new(
                expolygon       => $_,
                surface_type    => $group->[0]->surface_type,
            ), @{diff_ex(
                [ map $_->p, @$group ],
                [ map $_->p, @new_surfaces ],
            )};
        }
        @{$self->fill_surfaces} = @new_surfaces;
    }
    
    # detect bridge direction (skip bottom layer)
    if ($self->id > 0) {
        my @bottom  = grep $_->surface_type == S_TYPE_BOTTOM, @{$self->fill_surfaces};  # surfaces
        my @lower   = @{$self->layer->object->layers->[ $self->id - 1 ]->slices};       # expolygons
        
        foreach my $surface (@bottom) {
            # detect what edges lie on lower slices
            my @edges = (); # polylines
            foreach my $lower (@lower) {
                # turn bridge contour and holes into polylines and then clip them
                # with each lower slice's contour
                my @clipped = map $_->split_at_first_point->clip_with_polygon($lower->contour), @{$surface->expolygon};
                if (@clipped == 2) {
                    # If the split_at_first_point() call above happens to split the polygon inside the clipping area
                    # we would get two consecutive polylines instead of a single one, so we use this ugly hack to 
                    # recombine them back into a single one in order to trigger the @edges == 2 logic below.
                    # This needs to be replaced with something way better.
                    if (points_coincide($clipped[0][0], $clipped[-1][-1])) {
                        @clipped = (Slic3r::Polyline->new(@{$clipped[-1]}, @{$clipped[0]}));
                    }
                    if (points_coincide($clipped[-1][0], $clipped[0][-1])) {
                        @clipped = (Slic3r::Polyline->new(@{$clipped[0]}, @{$clipped[1]}));
                    }
                }
                push @edges, @clipped;
            }
            
            Slic3r::debugf "Found bridge on layer %d with %d support(s)\n", $self->id, scalar(@edges);
            next if !@edges;
            
            my $bridge_angle = undef;
            
            if (0) {
                require "Slic3r/SVG.pm";
                Slic3r::SVG::output("bridge.svg",
                    polygons        => [ $surface->p ],
                    red_polygons    => [ map @$_, @lower ],
                    polylines       => [ @edges ],
                );
            }
            
            if (@edges == 2) {
                my @chords = map Slic3r::Line->new($_->[0], $_->[-1]), @edges;
                my @midpoints = map $_->midpoint, @chords;
                my $line_between_midpoints = Slic3r::Line->new(@midpoints);
                $bridge_angle = Slic3r::Geometry::rad2deg_dir($line_between_midpoints->direction);
            } elsif (@edges == 1) {
                # TODO: this case includes both U-shaped bridges and plain overhangs;
                # we need a trapezoidation algorithm to detect the actual bridged area
                # and separate it from the overhang area.
                # in the mean time, we're treating as overhangs all cases where
                # our supporting edge is a straight line
                if (@{$edges[0]} > 2) {
                    my $line = Slic3r::Line->new($edges[0]->[0], $edges[0]->[-1]);
                    $bridge_angle = Slic3r::Geometry::rad2deg_dir($line->direction);
                }
            } elsif (@edges) {
                my $center = Slic3r::Geometry::bounding_box_center([ map @$_, @edges ]);
                my $x = my $y = 0;
                foreach my $point (map @$_, @edges) {
                    my $line = Slic3r::Line->new($center, $point);
                    my $dir = $line->direction;
                    my $len = $line->length;
                    $x += cos($dir) * $len;
                    $y += sin($dir) * $len;
                }
                $bridge_angle = Slic3r::Geometry::rad2deg_dir(atan2($y, $x));
            }
            
            Slic3r::debugf "  Optimal infill angle of bridge on layer %d is %d degrees\n",
                $self->id, $bridge_angle if defined $bridge_angle;
            
            $surface->bridge_angle($bridge_angle);
        }
    }
}

1;
