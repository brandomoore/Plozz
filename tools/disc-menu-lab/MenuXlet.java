package org.plozz.disclab;

import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics;
import java.awt.event.KeyEvent;
import javax.media.Manager;
import javax.media.MediaLocator;
import javax.media.Player;
import javax.media.ControllerEvent;
import javax.media.ControllerListener;
import javax.media.EndOfMediaEvent;
import javax.tv.service.selection.NormalContentEvent;
import javax.tv.service.selection.ServiceContext;
import javax.tv.service.selection.ServiceContextEvent;
import javax.tv.service.selection.ServiceContextFactory;
import javax.tv.service.selection.ServiceContextListener;
import javax.tv.service.selection.ServiceContextException;
import javax.tv.xlet.Xlet;
import javax.tv.xlet.XletContext;
import org.bluray.net.BDLocator;
import org.dvb.event.EventManager;
import org.dvb.event.UserEvent;
import org.dvb.event.UserEventListener;
import org.dvb.event.UserEventRepository;
import org.havi.ui.HContainer;
import org.havi.ui.HScene;
import org.havi.ui.HSceneFactory;

/** Original test content, not a production player or third-party disc application. */
public final class MenuXlet extends HContainer implements Xlet, UserEventListener, ServiceContextListener, ControllerListener {
    private HScene scene;
    private Player player;
    private ServiceContext serviceContext;
    private volatile int selected = 1;
    private volatile String failure;
    private volatile boolean shutdownProbe;

    public void initXlet(XletContext context) {
        SecurityManager security = System.getSecurityManager();
        if (security == null) {
            throw new IllegalStateException("BD-J security manager is missing");
        }
        boolean denied = false;
        try {
            security.checkConnect("127.0.0.1", 9);
        } catch (SecurityException expected) {
            denied = true;
        }
        if (!denied) {
            throw new IllegalStateException("Disc networking is not disabled");
        }
        System.out.println("PLOZZ_XLET network-permission-denied");
        requireDenied(new Runnable() {
            public void run() { security.checkRead("/private/plozz-outside-disc"); }
        });
        requireDenied(new Runnable() {
            public void run() { security.checkLink("untrusted-disc-library"); }
        });
        requireDenied(new Runnable() {
            public void run() { security.checkExit(0); }
        });
        scene = HSceneFactory.getInstance().getDefaultHScene();
        setBounds(0, 0, 1280, 720);
        scene.setLayout(null);
        scene.add(this);
        try {
            serviceContext = ServiceContextFactory.getInstance().getServiceContext(context);
            serviceContext.addListener(this);
        } catch (ServiceContextException error) {
            throw new IllegalStateException("Test title context unavailable", error);
        }
        UserEventRepository keys = new UserEventRepository("Plozz disc lab");
        keys.addAllArrowKeys();
        keys.addKey(KeyEvent.VK_ENTER);
        keys.addKey(KeyEvent.VK_ESCAPE);
        EventManager.getInstance().addUserEventListener(this, keys);
        System.out.println("PLOZZ_XLET initialized runtime=" + System.getProperty("java.vm.name"));
    }

    private static void requireDenied(Runnable operation) {
        try {
            operation.run();
        } catch (SecurityException expected) {
            return;
        }
        throw new IllegalStateException("Disc sandbox allowed a prohibited operation");
    }

    public void startXlet() {
        setVisible(true);
        scene.setVisible(true);
        setFocusable(true);
        requestFocus();
        repaint();
        System.out.println("PLOZZ_XLET started");
    }

    public void pauseXlet() {
        if (player != null) {
            player.stop();
        }
    }

    public void destroyXlet(boolean unconditional) {
        EventManager.getInstance().removeUserEventListener(this);
        serviceContext.removeListener(this);
        if (player != null) {
            player.stop();
            player.close();
            player = null;
        }
        scene.remove(this);
        scene.setVisible(false);
        HSceneFactory.getInstance().dispose(scene);
        System.out.println("PLOZZ_XLET destroyed");
    }

    public void receiveServiceContextEvent(ServiceContextEvent event) {
        if (event instanceof NormalContentEvent
                && ((BDLocator) serviceContext.getService().getLocator()).getTitleNumber() == 0) {
            if (player != null) {
                player.stop();
                player.close();
                player = null;
            }
            scene.setVisible(true);
            repaint();
        }
    }

    public void controllerUpdate(ControllerEvent event) {
        if (event instanceof EndOfMediaEvent) {
            scene.setVisible(true);
            repaint();
        }
    }

    public void userEventReceived(UserEvent event) {
        if (event.getType() != KeyEvent.KEY_PRESSED) {
            return;
        }
        switch (event.getCode()) {
            case KeyEvent.VK_LEFT:
            case KeyEvent.VK_UP:
                selected = 1;
                break;
            case KeyEvent.VK_RIGHT:
                selected = 2;
                break;
            case KeyEvent.VK_DOWN:
                // A bounded, interruption-resistant worker exercises incomplete shutdown.
                if (!shutdownProbe) {
                    new Thread(new Runnable() {
                        public void run() {
                            long until = System.nanoTime() + 30000000000L;
                            while (System.nanoTime() < until) {
                                try {
                                    Thread.sleep(100);
                                } catch (InterruptedException expected) { }
                            }
                        }
                    }, "Plozz shutdown fixture").start();
                    shutdownProbe = true;
                }
                break;
            case KeyEvent.VK_ENTER:
                playSelected();
                break;
            case KeyEvent.VK_ESCAPE:
                if (player != null) {
                    player.stop();
                    player.close();
                    player = null;
                }
                break;
            default:
                return;
        }
        System.out.println("PLOZZ_XLET selection=" + selected);
        repaint();
    }

    private void playSelected() {
        try {
            if (player != null) {
                player.stop();
                player.close();
            }
            BDLocator locator = new BDLocator(null, 1, selected);
            player = Manager.createPlayer(new MediaLocator(locator.toExternalForm()));
            player.addControllerListener(this);
            player.start();
            System.out.println("PLOZZ_XLET requested-playlist=" + selected);
        } catch (Exception error) {
            failure = error.toString();
            System.err.println("PLOZZ_XLET ERROR " + failure);
            error.printStackTrace();
        }
    }

    public void paint(Graphics graphics) {
        graphics.setColor(new Color(16, 20, 28));
        graphics.fillRect(0, 0, 1280, 720);
        graphics.setColor(Color.WHITE);
        graphics.setFont(new Font("Dialog", Font.BOLD, 40));
        graphics.drawString("Plozz BD-J experiment", 80, 110);
        graphics.setFont(new Font("Dialog", Font.PLAIN, 26));
        graphics.drawString("Original disc menu - arrow keys and select", 80, 160);
        for (int episode = 1; episode <= 2; episode++) {
            int x = 80 + (episode - 1) * 580;
            graphics.setColor(selected == episode ? Color.YELLOW : Color.GRAY);
            graphics.fillRect(x, 250, 520, 220);
            graphics.setColor(Color.BLACK);
            graphics.drawString("Episode " + episode, x + 40, 340);
            graphics.drawString(episode == 1 ? "Red test clip" : "Blue test clip", x + 40, 390);
        }
        if (failure != null) {
            graphics.setColor(Color.RED);
            graphics.drawString(failure, 80, 580);
        }
        if (shutdownProbe) {
            graphics.setColor(Color.RED);
            graphics.drawString("Shutdown regression armed", 80, 630);
        }
    }
}
