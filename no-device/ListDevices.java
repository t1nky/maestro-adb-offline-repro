import java.util.ArrayList;
import maestro.android.AndroidDeviceConnection;

/** Lists Android devices with Maestro's own code, through the adb server on the given port. */
public class ListDevices {
    public static void main(String[] args) {
        int port = Integer.parseInt(args[0]);
        try {
            var serials = new ArrayList<String>();
            for (var connection : AndroidDeviceConnection.Companion.listFromAdbServer(port, 7001)) {
                serials.add(connection.getSerial());
                connection.close();
            }
            System.out.println("listed " + serials);
        } catch (Exception e) {
            System.out.println("threw " + e);
        }
    }
}
