import javax.imageio.ImageIO;
import java.awt.AlphaComposite;
import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.GraphicsConfiguration;
import java.awt.GraphicsEnvironment;
import java.awt.Paint;
import java.awt.RenderingHints;
import java.awt.Shape;
import java.awt.Transparency;
import java.awt.geom.AffineTransform;
import java.awt.geom.Area;
import java.awt.geom.Ellipse2D;
import java.awt.geom.Path2D;
import java.awt.geom.Rectangle2D;
import java.awt.image.BufferedImage;
import java.io.File;

/**
 * Launcher icon renderer for "super market": a geometric ORCA in the
 * NEGATIVE-SPACE language of the user's reference logo (blue roundel,
 * same-family whale, all markings punched through to the field).
 *
 * Usage: java IconGen <mode> <size> <out.png>
 *   legacy     : sea-blue gradient CIRCLE + the orca; markings punched to
 *                the field gradient (two inks total, like the reference)
 *   foreground : transparent bg + the orca inside the 66/108 safe circle;
 *                markings are cut with DstOut so the adaptive background
 *                drawable (same gradient) shows through
 *
 * Outputs (all six are checked in; regenerate with tool/icongen/regen.sh):
 *   drawable-nodpi/ic_launcher_foreground.png        432 (foreground)
 *   mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png       48 / 72 / 96 / 144 / 192
 *
 * ## Design language (2026-11-05, negative-space rework)
 *
 * The user supplied a reference logo: a blue roundel with a same-colour
 * whale whose eye, belly and mouth are NEGATIVE SPACE. That language
 * replaces the previous multi-ink build (white patch/belly/leaf + grey
 * saddle): two inks only —
 *
 *   BACKGROUND  #FFFFFF  white roundel — user: "背景色用白色". The punched
 *                        markings show the WHITE, exactly like the
 *                        reference logo on its paper background.
 *   WHALE       #2F86D6  sea-blue orca (the project's sea hue, ~3.8:1 on
 *                        white — the reference's blue is the same idea)
 *
 *   negative space (white showing through): the spindle eye patch (whale-
 *   ink eyeball drawn back on top), the belly crescent, and a thin mouth
 *   line. The grey saddle patch and the white flank leaf are gone — on a
 *   white field they would be invisible anyway.
 *
 * Kept from the earlier reworks: the slender spindle body (~3.1:1 through
 * ELONG), wide-base dorsal, peduncle-first crescent tail, root-wide
 * flipper on the black/white boundary, tangent-continuous outline.
 *
 * Centring follows visual weight, not the bbox — see drawIcon().
 */
public class IconGen {

    // WHITE roundel + BLACK whale + white negative space — user:
    // "把蓝色变成黑色". Pure black reads crisp on white (21:1) and matches
    // the reference logo's one-ink weight.
    static final Color WHITE = Color.WHITE;
    static final Color WHALE = Color.BLACK;

    /**
     * Body elongation (user: "虎鲸要再长一点"): one uniform horizontal
     * stretch over ALL art. Data reads ~2.9:1; through ELONG ~3.3:1.
     * ELONG=1.0 disables.
     */
    static final double ELONG = 1.13;

    /** Map a design-grid x through the elongation (anchored at x=16). */
    static double mx(double x) {
        return ELONG * (x - 16) + 16;
    }

    /** Design grid is 180x180; everything below is in those units. */

    /** Head-left body: slender spindle, blunt snout, tapering tail stock. */
    static Path2D body() {
        Path2D p = new Path2D.Double();
        p.moveTo(22, 90);                        // snout tip
        p.curveTo(26, 77, 42, 68, 64, 63);       // forehead into the back
        p.curveTo(88, 59, 113, 64, 130, 75);     // back line: one long arc
        p.curveTo(140, 80, 143, 87, 141, 93);    // tail stock, tapering
        p.curveTo(139, 97, 130, 100, 120, 102);  // stock underside
        p.curveTo(96, 105, 60, 104, 40, 100);    // belly line
        p.curveTo(30, 97, 20, 93, 22, 90);       // jaw, round back to the snout
        p.closePath();
        return p;
    }

    /**
     * Dorsal fin, sized per the real animal (user: "背鳍是不是太大了"):
     * height ~39u ≈ 88% of body depth (real bull: 1.0-1.8 m vs ~2.3 m
     * depth ≈ 44-78%; a touch over for icon presence), base 72..106 =
     * 34u ≈ 26% of body length. Tangent-continuous at both landings.
     */
    static Path2D dorsal() {
        Path2D p = new Path2D.Double();
        p.moveTo(72, 63);
        p.curveTo(76, 58, 84, 36, 91, 24);      // leading edge, tangent-continuous
        p.curveTo(95, 38, 98, 56, 106, 65);     // concave trailing, tangent-landing
        p.curveTo(94, 63, 80, 63, 72, 63);      // base, along the back line
        p.closePath();
        return p;
    }

    /**
     * Tail: peduncle first, then the crescent — both lobes ~10u thick
     * (the upper one was 5-6u once and vanished at 48dp).
     */
    static Path2D tail() {
        Path2D p = new Path2D.Double();
        p.moveTo(126, 80);
        p.curveTo(134, 82, 142, 83, 146, 86);    // peduncle
        p.curveTo(153, 82, 161, 73, 163, 67);    // upper fluke: crescent sweep
        p.curveTo(166, 72, 162, 82, 150, 90);    // upper horn, inner edge lower
        p.curveTo(148, 92, 147, 94, 147, 96);    // notch upper wall
        p.quadTo(145, 99, 147, 102);             // deep notch
        p.curveTo(149, 105, 152, 110, 155, 116); // lower fluke, inner edge
        p.curveTo(156, 119, 156, 122, 153, 123); // lower horn, rounded tip
        p.curveTo(149, 121, 142, 114, 135, 105); // lower fluke, outer edge
        p.closePath();
        return p;
    }

    /**
     * Pectoral flipper: root-wide paddle ON the black/white boundary,
     * hanging down-back like the photo (~50°), ~25% of body length.
     */
    static Path2D flipper() {
        Path2D p = new Path2D.Double();
        p.moveTo(58, 86);
        p.curveTo(60, 95, 66, 104, 76, 110);     // lower edge: hanging sweep
        p.curveTo(82, 113, 87, 111, 85, 105);    // round tip
        p.curveTo(82, 100, 72, 93, 66, 88);      // upper edge, back to the root
        p.curveTo(62, 86, 59, 85, 58, 86);       // root, on the boundary
        p.closePath();
        return p;
    }

    /** Rotated belly crescent (front-high, back-low) + the flank leaf. */
    static Area belly() {
        AffineTransform tilt = AffineTransform.getTranslateInstance(60, 106);
        tilt.rotate(Math.toRadians(6));
        Ellipse2D main = new Ellipse2D.Double(-60, -20, 120, 40);
        Area a = new Area(tilt.createTransformedShape(main));
        a.add(new Area(new Ellipse2D.Double(104, 86, 32, 18)));
        a.intersect(new Area(body()));
        return a;
    }

    /** Spindle eye patch behind the eye, tilted -14°. Kept clear of BOTH
     *  the forehead outline (~3u above) and the belly top (~2.7u below):
     *  when the patch touched the forehead outline, the punch bit a notch
     *  out of it and the remaining blue read as a "spike" (user review). */
    static Shape eyePatch() {
        Path2D sp = new Path2D.Double();
        sp.moveTo(-12, 0);
        sp.quadTo(0, -4.75, 12, 0);
        sp.quadTo(0, 4.75, -12, 0);
        sp.closePath();
        AffineTransform tilt = AffineTransform.getTranslateInstance(48, 77);
        tilt.rotate(Math.toRadians(-14));
        return tilt.createTransformedShape(sp);
    }

    /** Mouth line: a thin arc along the jaw, above the belly crescent. */
    static Path2D mouthLine() {
        Path2D p = new Path2D.Double();
        p.moveTo(27, 92);
        p.quadTo(40, 99, 54, 95);
        return p;
    }

    static Area silhouette() {
        Area a = new Area(body());
        a.add(new Area(dorsal()));
        a.add(new Area(tail()));
        a.add(new Area(flipper()));
        return a;
    }

    static void drawIcon(Graphics2D g, int size, String mode) {
        boolean foreground = mode.equals("foreground");

        if (!foreground) {
            // White roundel, like the reference logo.
            g.setColor(WHITE);
            g.fillOval(0, 0, size, size);
        }

        Area silhouette = silhouette();
        Rectangle2D b = silhouette.getBounds2D();
        Rectangle2D b2 = new Rectangle2D.Double(
                mx(b.getX()), b.getY(), b.getWidth() * ELONG, b.getHeight());

        // Optical size from the (elongated) bounding box — never a fixed
        // factor: the tall fin changes the box. Foreground 0.60 keeps the
        // elongated whale just inside the 66/108 safe circle (0.611).
        double ratio = foreground ? 0.60 : 0.74;
        double s = Math.min(size * ratio / b2.getWidth(), size * ratio / b2.getHeight());

        // Centring: the WHOLE whale (tail included) is centred, then the
        // whole thing shifts LEFT 5.5% of the canvas (user: "再左移一点",
        // was 4%) — the tail sweeping right makes even a mathematically
        // centred bbox read right-heavy. y centres the full bbox then
        // shifts up 2% (thin tall fin carries no visual weight).
        double tx = size / 2.0 - size * 0.055
                - (mx(b.getX()) + b.getWidth() * ELONG / 2.0) * s;
        double ty = size / 2.0 - (b2.getY() + b2.getHeight() / 2.0) * s - size * 0.02;

        AffineTransform t = AffineTransform.getTranslateInstance(tx, ty);
        t.scale(s, s);
        t.translate(16, 0);      // elongation, anchored at design x=16 (snout)
        t.scale(ELONG, 1);

        // 1. sea-blue orca
        g.setColor(WHALE);
        g.fill(t.createTransformedShape(silhouette));

        // 2. negative space: eye patch, belly crescent, mouth line — punched
        //    through to the WHITE (DstOut in the foreground so the white
        //    adaptive background shows; white ink in legacy).
        if (foreground) {
            g.setComposite(AlphaComposite.DstOut);
            g.setColor(new Color(0, 0, 0, 255));
        } else {
            g.setColor(WHITE);
        }
        g.fill(t.createTransformedShape(eyePatch()));
        g.fill(t.createTransformedShape(belly()));
        g.setStroke(new BasicStroke(2.4f, BasicStroke.CAP_ROUND, BasicStroke.JOIN_ROUND));
        g.draw(t.createTransformedShape(mouthLine()));
        g.setComposite(AlphaComposite.SrcOver);

        // 3. flipper back on top: whale ink riding the punched belly's edge
        g.setColor(WHALE);
        g.fill(t.createTransformedShape(new Area(flipper())));

        // 4. eyeball: whale ink inside the punched patch (front-lower end)
        g.setColor(WHALE);
        double ex = mx(55) * s + tx;
        double ey = 75.5 * s + ty;
        g.fill(new Ellipse2D.Double(ex - 2.5 * s, ey - 2.5 * s, 5 * s, 5 * s));
    }

    static BufferedImage render(int size, String mode) {
        GraphicsConfiguration gc =
                GraphicsEnvironment.getLocalGraphicsEnvironment()
                        .getDefaultScreenDevice().getDefaultConfiguration();
        BufferedImage img = gc.createCompatibleImage(size, size, Transparency.TRANSLUCENT);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE);
        drawIcon(g, size, mode);
        g.dispose();
        return img;
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("usage: IconGen <legacy|foreground> <size> <out.png>");
            System.exit(2);
        }
        String mode = args[0];
        int size = Integer.parseInt(args[1]);
        File file = new File(args[2]);
        file.getParentFile().mkdirs();
        ImageIO.write(render(size, mode), "png", file);
        System.out.println("written " + args[2] + " (" + size + "x" + size + ", " + mode + ")");
    }
}
