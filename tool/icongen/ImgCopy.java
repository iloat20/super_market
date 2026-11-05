import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.File;

/** Copy an image to a new path (fresh bytes for image review). */
public class ImgCopy {
    public static void main(String[] a) throws Exception {
        BufferedImage in = ImageIO.read(new File(a[0]));
        ImageIO.write(in, "png", new File(a[1]));
        System.out.println("copied " + a[1]);
    }
}
