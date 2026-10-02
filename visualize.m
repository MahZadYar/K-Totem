%% 2D COMSOL Data Visualization
% =========================================================================
% Purpose:
%   Reads, processes, and visualizes 2D surface finite element analysis (FEA)
%   datasets exported from COMSOL Multiphysics (.txt format containing
%   coordinates, triangular mesh elements, and scalar nodal fields).
%   Generates publication-quality filled contour plots overlaid with the
%   underlying computational mesh wireframe and domain boundaries.
%
% Workflow:
%   1. Reads nodal coordinates, triangular mesh connectivities, and scalar data.
%   2. Applies optional in-plane planar rotations to align geometries.
%   3. Applies optional symmetrical logarithmic (symlog) scaling: sign(d)*ln(1+|d|/s0)
%      to capture wide dynamic ranges across positive/negative fields.
%   4. Interpolates onto a regular grid with bleed margins using natural-neighbor
%      interpolation and nearest-neighbor boundary extrapolation.
%   5. Overlays filled contour bands, FEA triangular wireframe, and domain boundaries.
%   6. Exports vector graphics (.svg), optional raster previews (.png), and
%      a standalone calibrated publication colorbar.
%
% Author: Maziar Moussavi (KTU Institute of Materials Science)
% =========================================================================

%% 1. USER CONFIGURATION & SIMULATION PARAMETERS
% =========================================================================

% --- 1.1 Dataset Identification & Spatial Alignment ---
% File prefixes of the COMSOL exported datasets to process
filenames = {'S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7', 'S8', 'S9', 'S10', 'S11', 'S12', 'S13', 'S14'};
% In-plane rotation angles (degrees) to align facets with desired display/fabrication axes
rotations = 35 * [0, 1, 0, 0, 1, 0, -1, -1, 0, 0, 0, 0, 0, 0]; % [deg]

% Dataset indices to process (defaults to all files; can be pre-set in workspace)
if ~exist('panels_to_process', 'var') || isempty(panels_to_process)
    panels_to_process = 1:length(filenames);
end

% --- 1.2 Data Scaling & Dynamic Range ---
apply_symlog = true;            % Enable symmetrical logarithmic (symlog) scaling
refinement   = 1e5;             % Symlog linear-to-log transition threshold s_0
cmax         = 2.0;             % Symmetrical upper limit for transformed values
cmin         = -cmax;           % Symmetrical lower limit (-2.0)
numLevels    = 50;              % Number of discrete contour levels / color bands
contour_levels = linspace(cmin, cmax, numLevels);

% --- 1.3 Grid Discretization & Bleed Margin ---
grid_resolution = 0.01;            % Regular interpolation grid spacing [m] (1 cm)
margin_cm       = 1.0;             % Outer bleed margin around dataset perimeter [cm]
margin_m        = margin_cm / 100; % Bleed margin converted to meters [m]

% --- 1.4 Graphic Styling & Line Widths ---
wireframe_color  = 'k';            % Color of FEA triangular wireframe lines (black)
wireframe_width  = 6.0;            % Line width of the FEA triangular wireframe [pt]
contour_line_col = 'w';            % Color of contour interval lines (white)
contour_line_w   = 6.0;            % Line width of contour interval lines [pt]
border_color     = 'k';            % Color of the outer dataset boundary border
border_width     = 6.0;            % Line width of the outer boundary border [pt]

% --- 1.5 Export & Display Options ---
export_svg       = true;           % Export vector graphics (.svg)
export_png       = false;          % Export raster preview (.png)
png_scale_factor = 1.0;            % Paper scaling factor for raster PNG export
png_dpi          = 150;            % Resolution for PNG export [DPI]
export_colorbar  = true;           % Generate and export standalone colorbar.svg
show_figures     = false;          % Set to true to display windows, false for headless batch
input_dir        = 'data\';        % Input directory
output_dir       = '.';            % Output directory ('.' for project root)

%% 2. COLORMAP DEFINITION & HSV INTERPOLATION
% =========================================================================
% Continuous palette anchors (interpolated smoothly across the spectrum):
palette_hex = ["#e1dbff", "#beb3ff", "#978eff", "#6b65ff", "#4544d8", ...
    "#003f9d", ...
    "#006ca2", "#008fae", "#00b5bc", "#6dd6c2", "#b5ebcd"];

palette_rgb = hex2rgb(palette_hex); % Convert hex codes to RGB triplets
palette_hsv = rgb2hsv(palette_rgb); % Interpolate smoothly along the spectrum in HSV color space

query_pts   = linspace(1, size(palette_hsv, 1), numLevels);
palette_hsv_interp = interp1(1:size(palette_hsv, 1), palette_hsv, query_pts);

% Flip colormap so that:
%   Negative values (cmin = -2.0) -> Turquoise (#b5ebcd)
%   Zero values     (c = 0.0)     -> Dark Blue (#003f9d)
%   Positive values (cmax = +2.0) -> Indigo (#e1dbff)
palette_hsv_flipped = flipud(palette_hsv_interp);
cmap = hsv2rgb(palette_hsv_flipped);

%% 3. BATCH PROCESSING: MESH & SCALAR FIELD DATASETS
% =========================================================================
total_start_time = tic;
fig_visibility = 'off';
if show_figures
    fig_visibility = 'on';
end

fprintf('\n=========================================================================\n');
fprintf(' Processing COMSOL Datasets (%d selected)\n', length(panels_to_process));
fprintf('=========================================================================\n');

for idx = 1:length(panels_to_process)
    k = panels_to_process(idx);
    panel_name = filenames{k};
    input_file = fullfile(input_dir, [panel_name, '.txt']);
    panel_start_time = tic;

    fprintf('\n[%d/%d] Processing Dataset: %s\n', idx, length(panels_to_process), panel_name);

    % Check file existence
    if ~isfile(input_file)
        warning('Dataset file not found: %s. Skipping.', input_file);
        continue;
    end

    %% 3.1 Read and Parse COMSOL Exported Data
    fprintf('  -> Reading mesh and nodal data from %s...\n', input_file);
    [coords, elements, raw_data] = readComsolData(input_file);
    num_nodes = size(coords, 1);
    num_elems = size(elements, 1);
    fprintf('     Extracted %d nodes, %d triangular elements.\n', num_nodes, num_elems);

    %% 3.2 Planar Coordinate Transformation (In-Plane Rotation)
    theta_rad = rotations(k) * pi / 180;
    x_orig = coords(:, 1);
    y_orig = coords(:, 2);
    x =  x_orig * cos(theta_rad) - y_orig * sin(theta_rad);
    y =  x_orig * sin(theta_rad) + y_orig * cos(theta_rad);

    %% 3.3 Data Scaling & Transformation
    if apply_symlog
        % Compresses wide dynamic ranges while retaining sign and zero-crossing
        scaled_data = sign(raw_data) .* log(1 + abs(raw_data) / refinement);
    else
        scaled_data = raw_data;
    end

    %% 3.4 Bounding Box & Bleed Margin Calculation
    % Expand domain boundaries by bleed margin
    x_min = min(x) - margin_m;
    x_max = max(x) + margin_m;
    y_min = min(y) - margin_m;
    y_max = max(y) + margin_m;

    dx_total = x_max - x_min;
    dy_total = y_max - y_min;

    %% 3.5 Regular Grid Discretization & Scattered Interpolation
    % Create fine regular grid for rendering crisp, continuous contour bands
    nx = ceil(dx_total / grid_resolution);
    ny = ceil(dy_total / grid_resolution);
    xg = linspace(x_min, x_max, nx);
    yg = linspace(y_min, y_max, ny);
    [Xg, Yg] = meshgrid(xg, yg);

    % Natural neighbor interpolation inside mesh; nearest-neighbor extrapolation
    % into the bleed margin to avoid NaNs and create seamless wrapped edges
    F = scatteredInterpolant(x, y, scaled_data, 'natural', 'nearest');
    Zg = F(Xg, Yg);

    % Clamp data to [cmin, cmax] so exterior bleed regions are filled with edge colors
    Zg = max(min(Zg, cmax), cmin);

    %% 3.6 Figure Setup & Rendering
    fig = figure('Name', ['COMSOL Visualization - ', panel_name], ...
        'Units', 'centimeters', ...
        'Visible', fig_visibility, ...
        'Color', 'none');

    % Maximize axes to cover entire figure canvas with zero margins
    ax = axes(fig, 'Units', 'normalized', 'Position', [0, 0, 1, 1]);

    % 1) Render filled contour bands
    contourf(ax, Xg, Yg, Zg, contour_levels, ...
        'LineColor', contour_line_col, ...
        'LineWidth', contour_line_w);
    clim(ax, [cmin, cmax]);
    colormap(ax, cmap);
    hold(ax, 'on');

    % 2) Overlay computational FEA triangular mesh wireframe
    triplot(elements, x, y, ...
        'Color', wireframe_color, ...
        'LineWidth', wireframe_width);

    % 3) Extract and render the structural outer perimeter boundary
    TR = triangulation(elements, x, y);
    b = freeBoundary(TR);
    border_nodes = [b(:, 1); b(1, 1)]; % Close polygon loop
    plot(ax, x(border_nodes), y(border_nodes), ...
        'Color', border_color, ...
        'LineWidth', border_width);

    % Format axes for true metric proportions
    axis(ax, 'equal');
    axis(ax, 'tight');
    axis(ax, 'off');

    %% 3.7 Vector Graphic (SVG) Export
    if export_svg
        svg_filename = fullfile(output_dir, [panel_name, '.svg']);
        fprintf('  -> Exporting vector SVG: %s (%.1f cm x %.1f cm)...\n', ...
            svg_filename, dx_total * 100, dy_total * 100);

        set(fig, 'PaperUnits', 'centimeters');
        set(fig, 'PaperPosition', [0, 0, dx_total * 100, dy_total * 100]);
        set(fig, 'PaperSize',     [dx_total * 100, dy_total * 100]);
        print(fig, svg_filename, '-dsvg', '-vector');
    end

    %% 3.8 Optional Raster (PNG) Export
    if export_png
        png_filename = fullfile(output_dir, [panel_name, '.png']);
        fprintf('  -> Exporting raster PNG: %s (%d DPI)...\n', png_filename, png_dpi);

        set(fig, 'PaperUnits', 'centimeters');
        set(fig, 'PaperPosition', [0, 0, (dx_total * 100) * png_scale_factor, ...
            (dy_total * 100) * png_scale_factor]);
        print(fig, png_filename, '-dpng', sprintf('-r%d', png_dpi));
    end

    % Close figure to free memory
    close(fig);
    fprintf('  -> Completed %s in %.2f seconds.\n', panel_name, toc(panel_start_time));
end

fprintf('\n=========================================================================\n');
fprintf(' Processing completed in %.2f seconds.\n', toc(total_start_time));
fprintf('=========================================================================\n');

%% 4. STANDALONE PUBLICATION COLORBAR GENERATION
% =========================================================================
if export_colorbar
    cb_start_time = tic;
    fprintf('\n--- Generating Standalone Publication Colorbar ---\n');

    % Toggle: normalize values symmetrically to [-1, +1]
    normalize_colorbar = true;

    % Invert symlog transformation to recover physical field values if applied:
    if apply_symlog
        original_levels = sign(contour_levels) .* refinement .* (exp(abs(contour_levels)) - 1);
    else
        original_levels = contour_levels;
    end

    % Symmetrical normalization:
    % Divides positive values by max(pos) and negative values by |min(neg)|
    if normalize_colorbar
        pos_max = max(original_levels(original_levels > 0));
        neg_min = min(original_levels(original_levels < 0));
        display_levels = original_levels;
        if ~isempty(pos_max) && pos_max > 0
            display_levels(original_levels > 0) = original_levels(original_levels > 0) / pos_max;
        end
        if ~isempty(neg_min) && neg_min < 0
            display_levels(original_levels < 0) = original_levels(original_levels < 0) / abs(neg_min);
        end
        cb_title = 'Normalized [-1, +1]';
    else
        display_levels = original_levels;
        cb_title = 'Scalar Field Value';
    end

    % Construct colorbar figure canvas (6 cm width x 20 cm height)
    cb_fig = figure('Name', 'COMSOL Colorbar', ...
        'Units', 'centimeters', ...
        'Position', [2, 2, 6, 20], ...
        'Visible', fig_visibility, ...
        'Color', 'w');

    % Primary axis for discrete color patches
    cb_ax = axes(cb_fig, 'Units', 'normalized', 'Position', [0.05, 0.08, 0.35, 0.84]);

    % Draw discrete color patches for each contour interval
    num_bands = length(contour_levels) - 1;
    for i = 1:num_bands
        y0 = (i - 1) / num_bands;
        y1 = i / num_bands;
        patch(cb_ax, [0, 1, 1, 0], [y0, y0, y1, y1], cmap(i, :), 'EdgeColor', 'none');
        hold(cb_ax, 'on');
    end

    set(cb_ax, 'XTick', [], 'YTick', [], 'Box', 'on', 'Layer', 'top');
    xlim(cb_ax, [0, 1]);
    ylim(cb_ax, [0, 1]);

    % Secondary transparent axis for numerical tick labels on right side
    label_ax = axes(cb_fig, 'Units', 'normalized', ...
        'Position', get(cb_ax, 'Position'), ...
        'Color', 'none', ...
        'XTick', [], ...
        'Box', 'off');
    set(label_ax, 'YAxisLocation', 'right');
    xlim(label_ax, [0, 1]);
    ylim(label_ax, [0, 1]);

    % Place tick mark at each contour level boundary
    tick_positions = linspace(0, 1, numLevels);
    tick_labels = cell(numLevels, 1);
    for i = 1:numLevels
        tick_labels{i} = sprintf('%+.3f', display_levels(i));
    end

    set(label_ax, 'YTick', tick_positions, ...
        'YTickLabel', tick_labels, ...
        'FontSize', 12, ...
        'FontName', 'Consolas', ...
        'TickLength', [0.02, 0]);

    % Add title above colorbar
    title(label_ax, cb_title, 'FontSize', 7, 'FontWeight', 'bold');

    % Export colorbar to SVG
    cb_output_file = fullfile(output_dir, 'colorbar.svg');
    fprintf('Exporting colorbar to %s...\n', cb_output_file);

    set(cb_fig, 'PaperUnits', 'centimeters');
    fig_pos = get(cb_fig, 'Position');
    set(cb_fig, 'PaperPosition', [0, 0, fig_pos(3), fig_pos(4)]);
    set(cb_fig, 'PaperSize',     [fig_pos(3), fig_pos(4)]);
    print(cb_fig, cb_output_file, '-dsvg', '-vector');

    if ~show_figures
        close(cb_fig);
    end
    fprintf('Colorbar exported successfully in %.2f seconds.\n', toc(cb_start_time));
end

disp('=== All visualization tasks completed successfully. ===');

%% 5. HELPER FUNCTIONS
% =========================================================================

function [coords, elements, data] = readComsolData(filePath)
% READCOMSOLDATA Parses coordinates, connectivities, and nodal data
% from a standard 2D COMSOL Multiphysics text export file.
%
% Outputs:
%   coords   - [N x 2] double matrix of nodal coordinates (x, y) [m]
%   elements - [M x 3] double matrix of 1-based triangular node indices
%   data     - [N x 1] double vector of nodal scalar field values

lines = readlines(filePath);

% Locate mandatory section headers
coord_idx = find(startsWith(lines, '% Coordinates'), 1);
elem_idx  = find(startsWith(lines, '% Elements (triangles)'), 1);
data_idx  = find(startsWith(lines, '% Data'), 1);

if isempty(coord_idx) || isempty(elem_idx) || isempty(data_idx)
    error('Invalid COMSOL file format: Missing section headers in %s', filePath);
end

% Fast vectorized extraction of coordinates
coord_lines = lines(coord_idx + 1 : elem_idx - 1);
coords = str2double(split(coord_lines, ';'));

% Fast vectorized extraction of element connectivity
elem_lines = lines(elem_idx + 1 : data_idx - 1);
elements = str2double(split(elem_lines, ';'));

% Fast vectorized extraction of nodal data values
num_nodes = size(coords, 1);
data_lines = lines(data_idx + 1 : data_idx + num_nodes);
data = str2double(data_lines);
end

function rgb = hexToRgb(hexList)
% HEXTORGB Converts hexadecimal color strings to RGB triplets [0, 1].
% Compatible across all MATLAB versions (built-in hex2rgb fallback).

if exist('hex2rgb', 'builtin') || exist('hex2rgb', 'file')
    rgb = hex2rgb(hexList);
    return;
end

hexList = string(hexList);
n = numel(hexList);
rgb = zeros(n, 3);
for i = 1:n
    h = char(hexList(i));
    if startsWith(h, '#')
        h = h(2:end);
    end
    if length(h) == 6
        rgb(i, 1) = hex2dec(h(1:2)) / 255.0;
        rgb(i, 2) = hex2dec(h(3:4)) / 255.0;
        rgb(i, 3) = hex2dec(h(5:6)) / 255.0;
    else
        error('Invalid hex color string: "%s"', hexList(i));
    end
end
end
