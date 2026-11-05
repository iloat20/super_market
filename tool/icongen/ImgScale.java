import javax.imageio.ImageIO;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.File;

/** Scale an image (fresh bytes for image review dedup). */
public class ImgScale {
    public static void main(String[] a) throws Exception {
        BufferedImage in = ImageIO.read(new File(a[0]));
        double f = Double.parseDouble(a[1]);
        int w = (int) Math.round(in.getWidth() * f);
        int h = (int) Math.round(in.getHeight() * f);
        BufferedImage out = new BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = out.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,
                RenderingHints.VALUE_INTERPOLATION_BILINEAR);
        g.drawImage(in, 0, 0, w, h, null);
        g.dispose();
        ImageIO.write(out, "png", new File(a[2]));
        System.out.println("scaled " + a[2]);
    }
}
